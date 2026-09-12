import DopaAuthorization
import DopaClient
import DopaProtocol
import Foundation
import Observation
import Darwin

@available(macOS 14.0, *)
@MainActor @Observable
public final class AppModel {
  public enum ConnectionState: Equatable { case connecting, connected, disconnected }
  public private(set) var connectionState: ConnectionState = .connecting
  public private(set) var snapshot: DaemonSnapshot?
  public private(set) var capabilities: Set<String> = []
  public private(set) var ownSessionID: String?
  public private(set) var schedule = Schedule()
  public private(set) var options = SessionOptions()
  public private(set) var busy = false
  public private(set) var authorizing = false
  public private(set) var cleanupUnconfirmed = false
  public private(set) var now = Date()
  public var message: String?

  @ObservationIgnored private let transport: any DaemonTransport
  public let currentUID: UInt32
  @ObservationIgnored private let authorize: @Sendable () async throws -> ManagementCredential
  @ObservationIgnored private var monitoring: Task<Void, Never>?
  @ObservationIgnored private var ticking: Task<Void, Never>?
  @ObservationIgnored private var shuttingDown = false
  @ObservationIgnored private var connectionGeneration: UInt64 = 0
  @ObservationIgnored private var revisionFloor: (instance: String, revision: String)?
  @ObservationIgnored private var pendingCleanupIDs: Set<String> = []

  public init(
    transport: any DaemonTransport = SocketTransport(),
    authorize: @escaping @Sendable () async throws -> ManagementCredential = { try await .request() },
    currentUID: UInt32 = geteuid()
  ) { self.transport = transport; self.authorize = authorize; self.currentUID = currentUID }

  public var sessions: [DaemonSession] { snapshot?.sessions ?? [] }
  public var canManage: Bool { connectionState == .connected && capabilities.contains("admin.stopSessions") }
  public var canStopAll: Bool {
    !sessions.isEmpty && sessions.allSatisfy(canStopSession)
  }
  public func canStopSession(_ session: DaemonSession) -> Bool {
    guard connectionState == .connected else { return false }
    return session.id == ownSessionID || canManage
      || (capabilities.contains("session.stopSessions") && session.peerUID == currentUID)
  }
  public var displaySleepPrevented: Bool? {
    guard connectionState == .connected, let snapshot, snapshot.isConfirmed else { return nil }
    return snapshot.keepDisplayOn
  }
  public var canStart: Bool {
    connectionState == .connected && snapshot?.isConfirmed == true && !busy && !cleanupUnconfirmed
      && schedule.draft == nil && schedule.validation(now: now) == nil
      && (snapshot?.phase == "idle" || snapshot?.phase == "active")
  }
  public var status: String {
    guard connectionState == .connected else {
      return connectionState == .connecting ? "接続中" : "接続を確認できません"
    }
    guard let snapshot, snapshot.isConfirmed else { return "電源状態を確認できません" }
    if cleanupUnconfirmed && ownSessionID == nil { return "停止を確認中" }
    if let ownSessionID, sessions.contains(where: { $0.id == ownSessionID }) { return "スリープ防止中" }
    return sessions.isEmpty ? "オフ" : "他プロセスで動作中"
  }
  public var statusSymbol: String {
    guard connectionState == .connected, snapshot?.isConfirmed == true else { return "exclamationmark.triangle" }
    return sessions.isEmpty ? "moon" : "cup.and.saucer.fill"
  }

  public func startMonitoring() {
    guard monitoring == nil, !shuttingDown else { return }
    monitoring = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.shuttingDown else { return }
        if !self.busy {
          if self.connectionState != .connected {
            do {
              try await self.connectOnce()
            } catch { await self.disconnected(error) }
          } else {
            do {
              try await self.pollOnce()
            } catch { await self.disconnected(error) }
          }
        }
        let delay: UInt64 = self.connectionState == .connected ? 250_000_000 : 3_000_000_000
        try? await Task.sleep(nanoseconds: delay)
      }
    }
    ticking = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.shuttingDown else { return }
        await self.advanceClock(to: Date())
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
    }
  }

  public func connectOnce() async throws {
    if let ownSessionID { cleanupUnconfirmed = true; pendingCleanupIDs.insert(ownSessionID) }
    ownSessionID = nil
    if schedule.running { schedule.stop() }
    revisionFloor = nil
    let handshake = try await transport.connect()
    guard !shuttingDown else { return }
    capabilities = handshake.capabilities
    connectionState = .connected
    connectionGeneration &+= 1
    accept(handshake.snapshot)
  }

  public func pollOnce() async throws {
    do { for event in try await transport.poll() { try accept(event) } }
    catch { await disconnected(error); throw error }
  }

  public func advanceClock(to date: Date) async {
    now = date
    if !busy, ownSessionID != nil, let deadline = schedule.deadline, deadline <= now {
      await stop()
    }
  }

  private func accept(_ next: DaemonSnapshot) {
    if let floor = revisionFloor, floor.instance == next.instanceID,
      !DaemonSnapshot.revision(next.revision, isAtLeast: floor.revision) { return }
    if let previous = snapshot {
      guard next.isAtLeastAsNew(as: previous) else { return }
      if next.instanceID != previous.instanceID { ownSessionID = nil; schedule.stop() }
    }
    snapshot = next
    if let ownSessionID {
      if let own = next.sessions.first(where: { $0.id == ownSessionID }) { options = own.options }
      else { self.ownSessionID = nil; schedule.stop() }
    }
    if ownSessionID == nil && next.isConfirmed,
      pendingCleanupIDs.isDisjoint(with: next.sessions.map(\.id)) {
      pendingCleanupIDs = []
      cleanupUnconfirmed = false
    }
    if let error = next.error { message = "電源設定の確認が必要です。\n\(error)" }
  }

  private func accept(_ event: JSONValue) throws {
    switch event["event"]?.stringValue {
    case "status.changed":
      guard let value = event["data"]?["snapshot"] else { throw SnapshotError.malformed }
      accept(try DaemonSnapshot(value))
    case "session.ended":
      guard let ownSessionID, event["data"]?["sessionId"]?.stringValue == ownSessionID else { return }
      self.ownSessionID = nil
      schedule.stop()
      if event["data"]?["cleanup"]?.stringValue != "confirmed" {
        pendingCleanupIDs.insert(ownSessionID)
        cleanupUnconfirmed = true
        message = "スリープ防止は終了しましたが、電源設定の復元を確認できません。"
      } else {
        switch event["data"]?["reason"]?.stringValue {
        case "lid_closed": message = "ディスプレイを閉じたため停止しました。"
        case "daemon_shutdown": message = "サービスの終了により停止しました。"
        case "user_stopped": message = "全体管理の操作により停止しました。"
        default: message = "サービスによりスリープ防止が終了しました。"
        }
      }
    default: break
    }
  }

  private func disconnected(_ error: Error) async {
    if let ownSessionID { cleanupUnconfirmed = true; pendingCleanupIDs.insert(ownSessionID) }
    connectionGeneration &+= 1
    connectionState = .disconnected
    snapshot = nil
    ownSessionID = nil
    capabilities = []
    if schedule.running { schedule.stop() }
    message = "サービスに接続できません。dopa-daemonの導入・起動を確認してください。\n\(error)"
    await transport.close()
  }

  private func recordMutation(_ response: JSONValue) throws {
    guard let revision = response["revision"]?.stringValue, !revision.isEmpty,
      revision.utf8.allSatisfy({ (48...57).contains($0) }), let snapshot else {
      throw SnapshotError.malformed
    }
    revisionFloor = (snapshot.instanceID, revision)
  }

  private func refresh() async throws {
    let value = try await transport.request(method: "status.get", params: .object([:]))
    accept(try DaemonSnapshot(value))
  }

  private func report(_ error: Error) async {
    if let auth = error as? DopaAuthorizationError {
      if auth != .cancelled { message = "管理者の認証を確認できませんでした。" }
      return
    }
    if let remote = error as? DopaRemoteError {
      switch remote.code {
      case "lid_closed": message = "ディスプレイが閉じています。開いてから操作してください。"
      case "permission_denied": message = "停止に必要な管理者権限を確認できませんでした。"
      case "recovery_failed": message = "電源設定の復元を確認できません。サービスの状態を確認してください。"
      case "power_conflict": message = "ほかのツールがスリープ設定を変更しているため開始できません。"
      default: message = "操作を完了できませんでした。\n\(remote.message)"
      }
      do { try await refresh() } catch { await disconnected(error) }
    } else { await disconnected(error) }
  }

  public func start() async {
    guard canStart, ownSessionID == nil else { return }
    // Validate the absolute time before contacting the daemon, then again after its response.
    var proposed = schedule
    do { try proposed.start(now: Date()) }
    catch { message = String(describing: error); return }
    busy = true
    defer { busy = false }
    cleanupUnconfirmed = true
    do {
      let result = try await transport.request(method: "session.acquire", params: .object(["options": options.json]))
      guard let id = result["sessionId"]?.stringValue else { throw SnapshotError.malformed }
      ownSessionID = id
      try recordMutation(result)
      cleanupUnconfirmed = false
      // Publish the same instant used for the deadline, so a stale display tick
      // cannot round the initial remaining duration up by an extra second.
      now = Date()
      do { try schedule.start(now: now) }
      catch {
        let released = try await transport.request(method: "session.release", params: .object(["sessionId": .string(id)]))
        try recordMutation(released)
        ownSessionID = nil
        schedule.stop()
        message = "指定した終了時刻を過ぎました。時刻を設定し直してください。"
      }
      try await refresh()
    } catch { await report(error) }
  }

  public func stop() async {
    guard !busy, let id = ownSessionID else { return }
    busy = true
    cleanupUnconfirmed = true
    pendingCleanupIDs.insert(id)
    defer { busy = false }
    do {
      let result = try await transport.request(method: "session.release", params: .object(["sessionId": .string(id)]))
      try recordMutation(result)
      cleanupUnconfirmed = false
      pendingCleanupIDs.remove(id)
      ownSessionID = nil
      schedule.stop()
      try await refresh()
    } catch { await report(error) }
  }

  public func setOptions(_ next: SessionOptions) async {
    guard !busy else { return }
    guard let id = ownSessionID else { options = next; return }
    busy = true
    defer { busy = false }
    do {
      let result = try await transport.request(method: "session.update", params: .object([
        "sessionId": .string(id), "options": next.json]))
      try recordMutation(result)
      options = next
      try await refresh()
    } catch { await report(error) }
  }

  public func stopSessions(_ ids: [String]) async {
    guard !busy, !authorizing, !ids.isEmpty else { return }
    if ids.count == 1, ids.first == ownSessionID { await stop(); return }
    let requested = sessions.filter { ids.contains($0.id) }
    if capabilities.contains("session.stopSessions"), connectionState == .connected,
      requested.allSatisfy({ $0.peerUID == currentUID }) {
      busy = true
      defer { busy = false }
      do {
        if let ownSessionID, ids.contains(ownSessionID) {
          cleanupUnconfirmed = true; pendingCleanupIDs.insert(ownSessionID)
        }
        let result = try await transport.request(method: "session.stopSessions", params: .object([
          "sessionIds": .array(ids.map(JSONValue.string))]))
        try recordMutation(result)
        try await refresh()
      } catch { await report(error) }
      return
    }
    guard canManage else { return }
    let generation = connectionGeneration
    authorizing = true
    defer { authorizing = false }
    do {
      let grant = try await authorize()
      // Authentication can take arbitrarily long. Monitoring and expiry remain
      // active during the prompt; never send to a replacement connection.
      guard !shuttingDown, canManage, generation == connectionGeneration else {
        message = "接続が変わったため停止を中止しました。対象を確認して操作し直してください。"
        return
      }
      guard !busy else { message = "ほかの操作が完了してから停止してください。"; return }
      busy = true
      defer { busy = false }
      if let ownSessionID, ids.contains(ownSessionID) {
        cleanupUnconfirmed = true; pendingCleanupIDs.insert(ownSessionID)
      }
      let result = try await transport.request(method: "admin.stopSessions", params: .object([
        "sessionIds": .array(ids.map(JSONValue.string)), "authorization": .string(grant.externalForm)]))
      try recordMutation(result)
      withExtendedLifetime(grant) {}
      try await refresh()
    } catch { await report(error) }
  }

  public func editDuration(_ text: String) { schedule.editDuration(text, now: Date()) }
  public func beginEditingBasis(_ basis: Schedule.Basis) {
    now = Date()
    schedule.beginEditingBasis(basis, now: now)
  }
  public func editEnd(_ text: String) { schedule.editEnd(text, now: Date()) }
  public func editEndDate(_ date: Date) { schedule.editEndDate(date, now: Date()) }
  public func cancelEdit() { schedule.cancel() }
  public func applyEdit() {
    now = Date()
    do { try schedule.confirm(now: now) }
    catch { message = String(describing: error) }
  }
  public func setUnlimited(_ enabled: Bool) { schedule.setUnlimited(enabled, now: Date()) }
  public func addTime(_ seconds: Int) { _ = schedule.addTime(seconds, now: Date()) }

  public func shutdown() async -> Bool {
    guard !busy else { message = "操作が完了してから終了してください。"; return false }
    if ownSessionID != nil {
      await stop()
      guard ownSessionID == nil, connectionState == .connected, snapshot?.isConfirmed == true else { return false }
    }
    guard !cleanupUnconfirmed else {
      message = "自分のセッションの停止・復元をまだ確認できません。サービスの接続と状態を確認してください。"
      return false
    }
    shuttingDown = true
    monitoring?.cancel()
    ticking?.cancel()
    await transport.close()
    return true
  }
}
