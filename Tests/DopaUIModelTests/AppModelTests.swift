import DopaClient
import DopaAuthorization
import DopaProtocol
import Foundation
import XCTest

@testable import DopaUIModel

@available(macOS 14.0, *)
@MainActor
final class AppModelTests: XCTestCase {
  func testStartingDurationPublishesMatchingClockBeforeStatusRefreshCompletes() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    model.editDuration("01:20:00")
    await model.advanceClock(to: Date().addingTimeInterval(-0.25))
    await transport.setStatusGetHeld(true)
    let beforeStart = Date()

    let startTask = Task { @MainActor in await model.start() }
    await transport.waitUntilStatusGetStarted()

    XCTAssertTrue(model.schedule.running)
    XCTAssertGreaterThanOrEqual(model.now, beforeStart)
    let remaining = model.schedule.deadline?.timeIntervalSince(model.now)
    XCTAssertEqual(remaining, 4_800)
    XCTAssertEqual(remaining.map { Int(ceil($0)) }, 4_800)

    await transport.releaseStatusGet()
    await startTask.value
  }

  func testApplyingDurationPublishesMatchingClockWithoutWaitingForTick() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    model.editDuration("01:20:00")
    await model.advanceClock(to: Date().addingTimeInterval(-0.25))
    let beforeApply = Date()

    model.applyEdit()

    XCTAssertNil(model.schedule.draft)
    XCTAssertGreaterThanOrEqual(model.now, beforeApply)
    let remaining = model.schedule.deadline?.timeIntervalSince(model.now)
    XCTAssertEqual(remaining, 4_800)
    XCTAssertEqual(remaining.map { Int(ceil($0)) }, 4_800)
  }

  func testEditIntentBasisForwardsFreezingAndPreservesInvalidDraft() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    let model = AppModel(transport: transport)
    model.beginEditingBasis(.end)
    XCTAssertEqual(model.schedule.basis, .end)
    let fixed = model.schedule.config
    model.beginEditingBasis(.end)
    XCTAssertEqual(model.schedule.config, fixed)
    model.editDuration("invalid")
    let invalid = model.schedule
    model.beginEditingBasis(.end)
    XCTAssertEqual(model.schedule, invalid)
    model.setUnlimited(true)
    let unlimited = model.schedule
    model.beginEditingBasis(.end)
    model.addTime(900)
    XCTAssertEqual(model.schedule, unlimited)
  }

  func testDateSelectionForwardsExactValueAndKeepsInvalidSelectionVisible() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    let selected = Date().addingTimeInterval(3600.375)
    model.editEndDate(selected)
    XCTAssertEqual(model.schedule.config, .end(selected))
    XCTAssertNil(model.schedule.draft)

    let past = Date().addingTimeInterval(-60)
    model.editEndDate(past)
    XCTAssertEqual(model.schedule.draft?.end, past)
    XCTAssertEqual(model.schedule.draft?.error, .expiredEndTime)
    XCTAssertEqual(model.schedule.config, .end(selected))
    XCTAssertFalse(model.canStart)
    model.cancelEdit()
    XCTAssertEqual(model.schedule.config, .end(selected))
  }

  func testDisconnectIsNotReportedAsOffAndReconnectDoesNotAcquireAgain() async throws {
    let running = modelSnapshotJSON(
      phase: "active",
      sessions: [modelSessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(running)),
      statusValue: running
    )
    let model = AppModel(transport: transport)

    try await model.connectOnce()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.status, "他プロセスで動作中")

    await transport.setPollFailure(.disconnected)
    do {
      try await model.pollOnce()
      XCTFail("pollOnce should surface a transport failure")
    } catch {
      // The model updates its state before propagating the failed poll.
    }

    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertNil(model.snapshot)
    XCTAssertEqual(model.status, "接続を確認できません")
    XCTAssertNotEqual(model.status, "オフ")

    await transport.setPollFailure(nil)
    try await model.connectOnce()

    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.status, "他プロセスで動作中")
    let methods = await transport.requestMethods()
    let connectCount = await transport.connectCount()
    XCTAssertFalse(methods.contains("session.acquire"), "reconnect must only observe the daemon")
    XCTAssertEqual(connectCount, 2)
  }

  func testRejectedOptionUpdateKeepsAppliedOptionsAndDraft() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertEqual(model.ownSessionID, "own")

    let originalOptions = model.options
    model.editDuration("00:30:00")
    XCTAssertNotNil(model.schedule.draft)
    await transport.setOptionFailure(true)

    await model.setOptions(SessionOptions(keepDisplayOn: true, stopOnLidClose: true))

    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.options, originalOptions)
    XCTAssertNotNil(model.schedule.draft)
    XCTAssertNotNil(model.message)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.update"))
    XCTAssertTrue(methods.contains("status.get"), "a rejected update refreshes the confirmed state")
  }

  func testOwnedSessionEndedEventStopsScheduleAndDiscardsDraft() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertEqual(model.ownSessionID, "own")

    model.editDuration("00:30:00")
    XCTAssertNotNil(model.schedule.draft)
    await transport.enqueue(.object([
      "event": .string("session.ended"),
      "data": .object([
        "sessionId": .string("own"),
        "reason": .string("user_stopped"),
        "cleanup": .string("confirmed"),
        "revision": .string("3"),
      ]),
    ]))

    try await model.pollOnce()

    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
    XCTAssertNil(model.schedule.draft)
    XCTAssertEqual(model.message, "全体管理の操作により停止しました。")
  }

  func testExpiryReleasesWhileExternalAuthorizationIsStillPending() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [
        modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187),
        modelSessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281),
      ],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(
        capabilities: ["admin.stopSessions"], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let authorization = AuthorizationSuspension()
    let model = AppModel(
      transport: transport,
      authorize: { try await authorization.request() }
    )
    try await model.connectOnce()
    await model.start()
    let deadline = try XCTUnwrap(model.schedule.deadline)
    XCTAssertEqual(model.ownSessionID, "own")

    let adminTask = Task { @MainActor in
      await model.stopSessions(["cli"])
    }
    await authorization.waitUntilStarted()
    XCTAssertTrue(model.authorizing)
    XCTAssertFalse(model.busy, "the authentication prompt must not block the local clock")

    await model.advanceClock(to: deadline.addingTimeInterval(1))

    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.release"))

    await authorization.succeed()
    await adminTask.value
    XCTAssertFalse(model.authorizing)
  }

  func testHiddenClockDoesNotPublishTicksButStillExpiresOwnSession() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    let published = model.now
    let deadline = try XCTUnwrap(model.schedule.deadline)

    await model.processClockTick(at: deadline.addingTimeInterval(-1))

    XCTAssertEqual(model.now, published)
    XCTAssertEqual(model.ownSessionID, "own")

    await model.processClockTick(at: deadline.addingTimeInterval(1))

    XCTAssertEqual(model.now, deadline.addingTimeInterval(1))
    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
  }

  func testVisibleClockPublishesTicks() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let model = AppModel(transport: MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle))
    model.setPresentationActive(true)
    let tick = Date().addingTimeInterval(10)

    await model.processClockTick(at: tick)

    XCTAssertEqual(model.now, tick)
    model.setPresentationActive(false)
  }

  func testStalePollSnapshotCannotClearOwnedIDAfterAcquire() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()

    await transport.setPollHeld(true)
    let pollTask = Task { @MainActor in
      try? await model.pollOnce()
    }
    await transport.waitUntilPollStarted()

    await transport.setStatusGetHeld(true)
    let startTask = Task { @MainActor in
      await model.start()
    }
    await transport.waitUntilStatusGetStarted()
    XCTAssertEqual(model.ownSessionID, "own", "the acquire response is already applied")

    let stale = modelSnapshotJSON(revision: "1", phase: "idle")
    let event = JSONValue.object([
      "event": .string("status.changed"),
      "data": .object(["snapshot": stale]),
    ])
    await transport.releasePoll(with: [event])
    await pollTask.value

    XCTAssertEqual(model.ownSessionID, "own")
    XCTAssertEqual(model.snapshot?.revision, "1")

    await transport.releaseStatusGet()
    await startTask.value
    XCTAssertEqual(model.ownSessionID, "own")
    XCTAssertEqual(model.snapshot?.revision, "3")
  }

  func testFailedReleaseKeepsSecondShutdownBlockedAfterDegradedEmptySnapshot() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let degraded = modelSnapshotJSON(
      revision: "5",
      phase: "degraded",
      sessions: [],
      systemSleepDisabled: false,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertEqual(model.ownSessionID, "own")

    await transport.setStatusValue(degraded)
    await transport.setReleaseFailure(true)

    let firstShutdown = await model.shutdown()
    XCTAssertFalse(firstShutdown)
    XCTAssertNil(model.ownSessionID)
    XCTAssertEqual(model.snapshot?.phase, "degraded")
    XCTAssertTrue(model.cleanupUnconfirmed)

    let secondShutdown = await model.shutdown()
    XCTAssertFalse(secondShutdown)
    let methods = await transport.requestMethods()
    XCTAssertEqual(methods.filter { $0 == "session.release" }.count, 1)
  }

  func testCancelledAuthorizationLeavesSnapshotAndSessionsUntouched() async throws {
    let active = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(
        capabilities: ["admin.stopSessions"], snapshot: try DaemonSnapshot(active)),
      statusValue: active
    )
    let authorization = AuthorizationSuspension()
    let model = AppModel(
      transport: transport,
      authorize: { try await authorization.request() }
    )
    try await model.connectOnce()
    let before = try XCTUnwrap(model.snapshot)

    let stopTask = Task { @MainActor in
      await model.stopSessions(["cli"])
    }
    await authorization.waitUntilStarted()
    XCTAssertTrue(model.authorizing)
    await authorization.cancel()
    await stopTask.value

    XCTAssertFalse(model.authorizing)
    XCTAssertFalse(model.busy)
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.snapshot, before)
    XCTAssertEqual(model.sessions.map(\.id), ["cli"])
    let methods = await transport.requestMethods()
    XCTAssertFalse(methods.contains("admin.stopSessions"))
    XCTAssertNil(model.message)
  }

  func testStoppingOnlyOwnSessionNeedsNeitherAdminCapabilityNorAuthorization() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true, keepDisplayOn: false)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied })
    try await model.connectOnce()
    await model.start()
    XCTAssertTrue(model.canStopAll)
    await transport.setStatusValue(modelSnapshotJSON(revision: "4", phase: "idle"))
    await model.stopSessions(["own"])
    XCTAssertNil(model.ownSessionID)
    XCTAssertEqual(model.connectionState, .connected)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.release"))
    XCTAssertFalse(methods.contains("admin.stopSessions"))
  }
}

private actor MockDaemonTransport: DaemonTransport {
  enum Failure: Error, Sendable {
    case disconnected
  }

  struct Request: Sendable {
    let method: String
    let params: JSONValue
  }

  private let handshake: DaemonHandshake
  private var statusValue: JSONValue
  private var events: [JSONValue] = []
  private var pollFailure: Failure?
  private var optionFailure = false
  private var releaseFailure = false
  private var requests: [Request] = []
  private var connects = 0
  private var holdPoll = false
  private var pollStarted = false
  private var pollStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var pollContinuation: CheckedContinuation<[JSONValue], Error>?
  private var holdStatusGet = false
  private var statusGetStarted = false
  private var statusGetStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var statusGetContinuation: CheckedContinuation<JSONValue, Error>?

  init(handshake: DaemonHandshake, statusValue: JSONValue) {
    self.handshake = handshake
    self.statusValue = statusValue
  }

  func connect() async throws -> DaemonHandshake {
    connects += 1
    return handshake
  }

  func request(method: String, params: JSONValue) async throws -> JSONValue {
    requests.append(Request(method: method, params: params))
    switch method {
    case "status.get":
      if holdStatusGet {
        statusGetStarted = true
        let waiters = statusGetStartWaiters
        statusGetStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
          statusGetContinuation = continuation
        }
      }
      return statusValue
    case "session.acquire":
      return .object(["sessionId": .string("own"), "revision": .string("2")])
    case "session.update":
      if optionFailure {
        throw DopaRemoteError(code: "permission_denied", message: "fixture rejected options")
      }
      return .object(["revision": .string("4")])
    case "session.release":
      if releaseFailure {
        throw DopaRemoteError(code: "recovery_failed", message: "fixture could not confirm cleanup")
      }
      return .object(["revision": .string("4")])
    case "admin.stopSessions", "session.stopSessions":
      return .object(["revision": .string("5")])
    default:
      return .object([:])
    }
  }

  func poll() async throws -> [JSONValue] {
    if let pollFailure { throw pollFailure }
    if holdPoll {
      pollStarted = true
      let waiters = pollStartWaiters
      pollStartWaiters.removeAll()
      waiters.forEach { $0.resume() }
      return try await withCheckedThrowingContinuation { continuation in
        pollContinuation = continuation
      }
    }
    let next = events
    events.removeAll()
    return next
  }

  func close() async {}

  func setPollFailure(_ failure: Failure?) {
    pollFailure = failure
  }

  func setOptionFailure(_ enabled: Bool) {
    optionFailure = enabled
  }

  func setReleaseFailure(_ enabled: Bool) {
    releaseFailure = enabled
  }

  func setStatusValue(_ value: JSONValue) {
    statusValue = value
  }

  func setPollHeld(_ held: Bool) {
    holdPoll = held
  }

  func waitUntilPollStarted() async {
    if pollStarted { return }
    await withCheckedContinuation { continuation in
      pollStartWaiters.append(continuation)
    }
  }

  func releasePoll(with values: [JSONValue] = []) {
    events.append(contentsOf: values)
    holdPoll = false
    guard let continuation = pollContinuation else { return }
    pollContinuation = nil
    let next = events
    events.removeAll()
    continuation.resume(returning: next)
  }

  func setStatusGetHeld(_ held: Bool) {
    holdStatusGet = held
  }

  func waitUntilStatusGetStarted() async {
    if statusGetStarted { return }
    await withCheckedContinuation { continuation in
      statusGetStartWaiters.append(continuation)
    }
  }

  func releaseStatusGet() {
    holdStatusGet = false
    guard let continuation = statusGetContinuation else { return }
    statusGetContinuation = nil
    continuation.resume(returning: statusValue)
  }

  func enqueue(_ event: JSONValue) {
    events.append(event)
  }

  func requestMethods() -> [String] {
    requests.map(\.method)
  }

  func connectCount() -> Int {
    connects
  }
}

private actor AuthorizationSuspension {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<ManagementCredential, Error>?

  func request() async throws -> ManagementCredential {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func succeed() {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(returning: ManagementCredential(externalForm: "fixture-credential"))
  }

  func cancel() {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(throwing: DopaAuthorizationError.cancelled)
  }
}

private func modelSnapshotJSON(
  instanceID: String = "daemon-a",
  revision: String = "1",
  phase: String = "idle",
  sessions: [JSONValue] = [],
  systemSleepDisabled: Bool? = false,
  keepDisplayOn: Bool? = false,
  recoveryPending: Bool = false
) -> JSONValue {
  var confirmed: [String: JSONValue] = [:]
  if let systemSleepDisabled { confirmed["systemSleepDisabled"] = .bool(systemSleepDisabled) }
  if let keepDisplayOn { confirmed["keepDisplayOn"] = .bool(keepDisplayOn) }
  return .object([
    "instanceId": .string(instanceID),
    "revision": .string(revision),
    "phase": .string(phase),
    "sessions": .array(sessions),
    "recoveryPending": .bool(recoveryPending),
    "confirmed": .object(confirmed),
  ])
}

private func modelSessionJSON(
  id: String,
  clientName: String,
  pid: Int32,
  keepDisplayOn: Bool = false,
  stopOnLidClose: Bool = false,
  peerUID: UInt32? = nil
) -> JSONValue {
  var fields: [String: JSONValue] = [
    "id": .string(id),
    "clientName": .string(clientName),
    "peerPID": .number(Double(pid)),
    "options": .object([
      "keepDisplayOn": .bool(keepDisplayOn),
      "stopOnLidClose": .bool(stopOnLidClose),
    ]),
  ]
  if let peerUID { fields["peerUID"] = .number(Double(peerUID)) }
  return .object(fields)
}

@available(macOS 14.0, *)
@MainActor
extension AppModelTests {
  func testSameUIDStopsUseUnprivilegedCapabilityWithoutAuthorization() async throws {
    let active = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "a", clientName: "CLI", pid: 1, peerUID: 501),
      modelSessionJSON(id: "b", clientName: "CLI", pid: 2, peerUID: 501)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["session.stopSessions", "admin.stopSessions"], snapshot: try DaemonSnapshot(active)),
      statusValue: modelSnapshotJSON(revision: "5"))
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied }, currentUID: 501)
    try await model.connectOnce()
    XCTAssertTrue(model.canStopAll)
    await model.stopSessions(["a", "b"])
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.stopSessions"))
    XCTAssertFalse(methods.contains("admin.stopSessions"))
    XCTAssertTrue(model.sessions.isEmpty)
    XCTAssertNil(model.message)
  }

  func testUnknownAndOtherUIDCannotUseUnprivilegedStop() async throws {
    for uid: UInt32? in [nil, 502] {
      let active = modelSnapshotJSON(phase: "active", sessions: [
        modelSessionJSON(id: "a", clientName: "CLI", pid: 1, peerUID: 501),
        modelSessionJSON(id: "b", clientName: "CLI", pid: 2, peerUID: uid)], systemSleepDisabled: true)
      let transport = MockDaemonTransport(handshake: DaemonHandshake(
        capabilities: ["session.stopSessions"], snapshot: try DaemonSnapshot(active)), statusValue: active)
      let model = AppModel(transport: transport, currentUID: 501)
      try await model.connectOnce()
      XCTAssertTrue(model.canStopSession(model.sessions[0]))
      XCTAssertFalse(model.canStopSession(model.sessions[1]))
      XCTAssertFalse(model.canStopAll)
      await model.stopSessions(["a", "b"])
      let methods = await transport.requestMethods()
      XCTAssertFalse(methods.contains("session.stopSessions"))
    }
  }

  func testDisplaySleepPreventedUsesConfirmedAggregateInsteadOfOwnOptions() async throws {
    let active = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "cli", clientName: "CLI", pid: 1, keepDisplayOn: true)],
      systemSleepDisabled: true, keepDisplayOn: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(capabilities: [],
      snapshot: try DaemonSnapshot(active)), statusValue: active)
    let model = AppModel(transport: transport)
    XCTAssertNil(model.displaySleepPrevented)
    try await model.connectOnce()
    XCTAssertFalse(model.options.keepDisplayOn)
    XCTAssertEqual(model.displaySleepPrevented, true)
    for state in [
      modelSnapshotJSON(revision: "2", phase: "degraded"),
      modelSnapshotJSON(revision: "3", keepDisplayOn: nil),
      modelSnapshotJSON(revision: "4", keepDisplayOn: true)] {
      await transport.enqueue(.object(["event": .string("status.changed"), "data": .object(["snapshot": state])]))
      try await model.pollOnce()
      XCTAssertNil(model.displaySleepPrevented)
    }
  }
}

@available(macOS 14.0, *)
@MainActor
extension AppModelTests {
  func testLegacyAdminCapabilityKeepsAuthorizationRoute() async throws {
    let active = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "cli", clientName: "CLI", pid: 1)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["admin.stopSessions"], snapshot: try DaemonSnapshot(active)),
      statusValue: modelSnapshotJSON(revision: "5"))
    let model = AppModel(transport: transport,
      authorize: { ManagementCredential(externalForm: "fixture-credential") }, currentUID: 501)
    try await model.connectOnce()
    XCTAssertTrue(model.canStopAll)
    await model.stopSessions(["cli"])
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("admin.stopSessions"))
    XCTAssertFalse(methods.contains("session.stopSessions"))
    XCTAssertTrue(model.sessions.isEmpty)
  }

  func testSameUIDBulkStopClearsOwnedScheduleAfterConfirmedRefresh() async throws {
    let running = modelSnapshotJSON(revision: "3", phase: "active", sessions: [
      modelSessionJSON(id: "own", clientName: "UI", pid: 1, peerUID: 501),
      modelSessionJSON(id: "cli", clientName: "CLI", pid: 2, peerUID: 501)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["session.stopSessions"], snapshot: try DaemonSnapshot(modelSnapshotJSON())), statusValue: running)
    let model = AppModel(transport: transport, currentUID: 501)
    try await model.connectOnce()
    await model.start()
    XCTAssertTrue(model.schedule.running)
    await transport.setStatusValue(modelSnapshotJSON(revision: "5"))
    await model.stopSessions(["own", "cli"])
    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
    XCTAssertFalse(model.cleanupUnconfirmed)
    XCTAssertTrue(model.canStart)
  }
}

@available(macOS 14.0, *)
@MainActor
extension AppModelTests {
  func testSelectionWithAlreadyEndedSessionStillUsesUnprivilegedStop() async throws {
    let selected = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "remaining", clientName: "CLI", pid: 1, peerUID: 501),
      modelSessionJSON(id: "ended", clientName: "CLI", pid: 2, peerUID: 501)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["session.stopSessions", "admin.stopSessions"], snapshot: try DaemonSnapshot(selected)),
      statusValue: modelSnapshotJSON(revision: "5"))
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied }, currentUID: 501)
    try await model.connectOnce()
    let selectedIDs = model.sessions.map(\.id)
    let remaining = modelSnapshotJSON(revision: "2", phase: "active", sessions: [
      modelSessionJSON(id: "remaining", clientName: "CLI", pid: 1, peerUID: 501)], systemSleepDisabled: true)
    await transport.enqueue(.object(["event": .string("status.changed"), "data": .object(["snapshot": remaining])]))
    try await model.pollOnce()
    await model.stopSessions(selectedIDs)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.stopSessions"))
    XCTAssertFalse(methods.contains("admin.stopSessions"))
    XCTAssertTrue(model.sessions.isEmpty)
    XCTAssertNil(model.message)
  }
}
