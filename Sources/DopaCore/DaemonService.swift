import CDopa
import Darwin
import DopaAuthorization
import DopaProtocol
import Foundation

public enum DaemonService {
  public static func run(
    statePath: String = "/var/db/dopa", socketPath: String = "/var/run/dopa/control.sock",
    allowedUID: uid_t, power: any Power, controls: any Controls, requireRoot: Bool = true,
    authorizationVerifier: ((Data) -> Bool)? = nil
  ) throws {
    guard !requireRoot || geteuid() == 0 else { throw DopaError("daemon run requires root") }
    let state = try State(path: statePath)
    let engine = DaemonEngine(
      state: state, power: power, controls: controls,
      authorizationVerifier: authorizationVerifier ?? DopaAuthorization.verifyExternalForm)
    let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
    // Resolve system aliases above the managed directory, never the directory itself.
    let parentURL = URL(fileURLWithPath: parent)
    let safeParent = parentURL.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(parentURL.lastPathComponent).path
    if mkdir(safeParent, 0o755) != 0 && errno != EEXIST {
      throw systemError("create socket directory")
    }
    var info = stat()
    guard lstat(safeParent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o022 == 0
    else { throw DopaError("unsafe socket directory") }
    let path = URL(fileURLWithPath: safeParent).appendingPathComponent(
      URL(fileURLWithPath: socketPath).lastPathComponent
    ).path
    if lstat(path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
        throw DopaError("unsafe existing socket")
      }
      guard unlink(path) == 0 else { throw systemError("remove stale socket") }
    } else if errno != ENOENT {
      throw systemError("inspect socket")
    }
    let fd = dopa_unix_socket()
    guard fd >= 0 else { throw systemError("create daemon socket") }
    let listener = Descriptor(fd)
    guard dopa_unix_bind(fd, path) == 0 else { throw systemError("bind daemon socket") }
    defer {
      _ = unlink(path)
      withExtendedLifetime((state, listener)) {}
    }
    guard chmod(path, 0o666) == 0, dopa_unix_listen(fd, 64) == 0 else {
      throw systemError("listen daemon socket")
    }
    var finished = false
    defer { if !finished { try? engine.prepareShutdown() } }
    var peers: [Int32: ServicePeer] = [:]
    var nextCheck = Date.distantPast
    var nextLid = Date.distantPast
    func publish() {
      let events = engine.takeEvents()
      for (owner, event) in events { peers[owner]?.enqueue(event) }
      if engine.changed {
        engine.changed = false
        let event = JSONValue.object([
          "event": .string("status.changed"),
          "data": .object([
            "instanceId": .string(engine.instanceID), "revision": .string(String(engine.revision)),
            "snapshot": engine.snapshot(),
          ]),
        ])
        for peer in peers.values where peer.subscribed { peer.enqueue(event) }
      }
    }
    while dopa_stop_requested() == 0 {
      var polls = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
      for peer in peers.values {
        polls.append(
          pollfd(
            fd: peer.fd.value, events: Int16(POLLIN) | (peer.output.isEmpty ? 0 : Int16(POLLOUT)),
            revents: 0))
      }
      let result = poll(&polls, nfds_t(polls.count), 50)
      if result < 0 && errno != EINTR { throw systemError("poll daemon") }
      if polls[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
        throw DopaError("daemon listener failed")
      }
      if polls[0].revents & Int16(POLLIN) != 0 {
        for _ in 0..<16 {
          let client = dopa_unix_accept(fd)
          if client < 0 { break }
          let descriptor = Descriptor(client)
          var uid: uid_t = 0
          var pid: pid_t = 0
          guard peers.count < 64, dopa_unix_peer_uid(client, &uid) == 0,
            uid == allowedUID || uid == 0, dopa_unix_peer_pid(client, &pid) == 0
          else { continue }
          var noSignal: Int32 = 1
          _ = setsockopt(
            client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
          peers[client] = ServicePeer(fd: descriptor, uid: uid, pid: pid)
        }
      }
      for entry in polls.dropFirst() {
        guard let peer = peers[entry.fd] else { continue }
        if entry.revents & Int16(POLLIN | POLLHUP) != 0 && !peer.closing {
          var bytes = [UInt8](repeating: 0, count: 16_384)
          let count = Darwin.read(entry.fd, &bytes, bytes.count)
          if count > 0 {
            do {
              if peer.partialSince == nil { peer.partialSince = Date() }
              let frames = try peer.input.append(Data(bytes.prefix(count)))
              guard frames.count <= 16 else { throw DopaError("too many pending requests") }
              if bytes.prefix(count).last == 10 {
                peer.partialSince = nil
              } else if !frames.isEmpty {
                peer.partialSince = Date()
              }
              for frame in frames {
                peer.enqueue(engine.handle(frame, peer: peer))
                publish()
                if peer.closing { break }
              }
            } catch {
              peer.enqueue(
                .object([
                  "id": .null,
                  "error": .object([
                    "code": .string("invalid_request"),
                    "message": .string("invalid or excessive JSON frames"),
                  ]),
                ]))
              peer.closing = true
            }
          } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            peer.dead = true
          }
        }
        if !peer.output.isEmpty {
          let sent = peer.output.withUnsafeBytes {
            Darwin.write(entry.fd, $0.baseAddress, $0.count)
          }
          if sent > 0 {
            peer.output.removeFirst(sent)
          } else if sent < 0 && errno != EAGAIN && errno != EINTR {
            peer.dead = true
          }
        }
        if entry.revents & Int16(POLLERR | POLLNVAL) != 0 { peer.dead = true }
      }
      let now = Date()
      for (id, peer) in peers {
        if (!peer.hello && now.timeIntervalSince(peer.created) > 5)
          || (peer.partialSince.map { now.timeIntervalSince($0) > 5 } ?? false)
          || (peer.closing && peer.output.isEmpty) || peer.dead
        {
          engine.disconnect(id)
          peers.removeValue(forKey: id)
        }
      }
      if now >= nextLid {
        engine.checkLid()
        nextLid = now.addingTimeInterval(0.3)
      }
      if !peers.isEmpty && now >= nextCheck {
        engine.checkPower()
        nextCheck = now.addingTimeInterval(1)
      }
      publish()
    }
    try engine.prepareShutdown()
    finished = true
    publish()
    // Best effort event delivery; restoration never waits for a slow reader.
    for peer in peers.values {
      _ = peer.output.withUnsafeBytes { Darwin.write(peer.fd.value, $0.baseAddress, $0.count) }
    }
  }
}

final class ServicePeer {
  let fd: Descriptor
  let uid: uid_t
  let pid: pid_t
  let created = Date()
  var partialSince: Date?
  var input = JSONLineBuffer()
  var output = Data()
  var hello = false
  var name = "unknown"
  var subscribed = false
  var closing = false
  var dead = false
  var ids = Set<String>()
  var ended: [String] = []
  init(fd: Descriptor, uid: uid_t, pid: pid_t) {
    self.fd = fd
    self.uid = uid
    self.pid = pid
  }
  func enqueue(_ value: JSONValue) {
    guard !dead else { return }
    guard let data = try? JSONWire.encode(value), output.count + data.count <= 262_144 else {
      dead = true
      return
    }
    output.append(data)
  }
}

private struct APIError: Error {
  let code: String
  let message: String
  let details: JSONValue?
  init(_ code: String, _ message: String, details: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }
}

final class DaemonEngine {
  struct Owned {
    let id: String
    let peer: ServicePeer
    var options: Options
    let created: String
  }
  let state: State
  let power: any Power
  let controls: any Controls
  let authorizationVerifier: (Data) -> Bool
  let instanceID = UUID().uuidString
  var revision: UInt64 = 0
  var changed = false
  var sessions: [Int32: Owned] = [:]
  var phase = "recovering"
  var disabled: Bool?
  var display: Bool? = false
  var checked = ""
  var lastError: JSONValue = .null
  var draining = false
  private var events: [(Int32, JSONValue)] = []
  init(
    state: State, power: any Power, controls: any Controls,
    authorizationVerifier: @escaping (Data) -> Bool = DopaAuthorization.verifyExternalForm
  ) {
    self.state = state
    self.power = power
    self.controls = controls
    self.authorizationVerifier = authorizationVerifier
    do {
      try Session.recover(power: power, state: state)
      disabled = try power.readDisabled()
      phase = "idle"
    } catch {
      phase = "degraded"
      lastError = errorValue("recovery_failed", "\(error)")
    }
    checked = timestamp()
  }
  private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
  private func errorValue(_ code: String, _ message: String, details: JSONValue? = nil) -> JSONValue
  {
    var object: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
    if let details { object["details"] = details }
    return .object(object)
  }
  private func bump() {
    revision += 1
    changed = true
  }
  func takeEvents() -> [(Int32, JSONValue)] {
    defer { events.removeAll() }
    return events
  }
  func snapshot() -> JSONValue {
    .object([
      "instanceId": .string(instanceID), "revision": .string(String(revision)),
      "phase": .string(phase),
      "desired": .object([
        "systemSleepDisabled": .bool(!sessions.isEmpty),
        "keepDisplayOn": .bool(sessions.values.contains { $0.options.keepDisplayOn }),
      ]),
      "confirmed": .object([
        "systemSleepDisabled": disabled.map(JSONValue.bool) ?? .null,
        "keepDisplayOn": display.map(JSONValue.bool) ?? .null, "checkedAt": .string(checked),
      ]),
      "sessions": .array(
        sessions.values.sorted { $0.id < $1.id }.map { s in
          .object([
            "id": .string(s.id), "clientName": .string(s.peer.name),
            "peerUID": .number(Double(s.peer.uid)), "peerPID": .number(Double(s.peer.pid)),
            "options": optionsValue(s.options), "createdAt": .string(s.created),
          ])
        }),
      "recoveryPending": .bool((try? state.pending()) ?? true), "lastError": lastError,
    ])
  }
  private func optionsValue(_ options: Options) -> JSONValue {
    .object([
      "keepDisplayOn": .bool(options.keepDisplayOn),
      "stopOnLidClose": .bool(options.stopOnLidClose),
    ])
  }
  private func fields(_ value: JSONValue, _ keys: Set<String>) throws -> [String: JSONValue] {
    guard let object = value.objectValue, Set(object.keys) == keys else {
      throw APIError("invalid_params", "unexpected or missing fields")
    }
    return object
  }
  private func options(_ value: JSONValue) throws -> Options {
    let object = try fields(value, ["keepDisplayOn", "stopOnLidClose"])
    guard let display = object["keepDisplayOn"]?.boolValue,
      let lid = object["stopOnLidClose"]?.boolValue
    else { throw APIError("invalid_params", "options must be boolean") }
    return Options(keepDisplayOn: display, stopOnLidClose: lid)
  }
  private func checkLidBefore(_ options: Options) throws {
    if options.stopOnLidClose {
      let closed: Bool
      do { closed = try controls.lidClosed() } catch {
        throw APIError("lid_unavailable", "\(error)")
      }
      if closed { throw APIError("lid_closed", "lid is already closed") }
    }
  }
  func handle(_ request: JSONValue, peer: ServicePeer) -> JSONValue {
    var id: JSONValue = .null
    do {
      guard let object = request.objectValue, Set(object.keys) == ["id", "method", "params"],
        let requestID = object["id"]?.stringValue, !requestID.isEmpty, requestID.utf8.count <= 64,
        requestID.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
        let method = object["method"]?.stringValue, let params = object["params"],
        params.objectValue != nil
      else {
        peer.closing = true
        throw APIError("invalid_request", "invalid request envelope")
      }
      id = .string(requestID)
      guard peer.ids.insert(requestID).inserted else {
        peer.closing = true
        throw APIError("invalid_request", "duplicate request id")
      }
      // Bound replay bookkeeping as well as byte queues.
      guard peer.ids.count <= 65_536 else {
        peer.closing = true
        throw APIError("limit_exceeded", "request limit; reconnect")
      }
      guard peer.hello || method == "hello" else { throw APIError("not_ready", "hello required") }
      let result: JSONValue
      switch method {
      case "hello":
        guard !peer.hello else { throw APIError("invalid_request", "hello already completed") }
        let p = try fields(params, ["apiVersion", "client"])
        guard p["apiVersion"] == .number(1) else {
          peer.closing = true
          throw APIError(
            "unsupported_version", "unsupported API version",
            details: .object(["supportedVersions": .array([.number(1)])]))
        }
        let client = try fields(p["client"]!, ["name", "version"])
        guard let name = client["name"]?.stringValue, name.utf8.count <= 128,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let version = client["version"]?.stringValue, version.utf8.count <= 128
        else { throw APIError("invalid_params", "invalid client name or version") }
        peer.name = name
        peer.hello = true
        result = .object([
          "apiVersion": .number(1), "daemonVersion": .string(DopaProtocol.clientVersion),
          "instanceId": .string(instanceID),
          "capabilities": .array([
            .string("status.subscribe"), .string("session.update"),
            .string("session.stopSessions"), .string("admin.stopSessions"),
          ]),
          "limits": .object([
            "maxMessageBytes": .number(65_536), "maxSessions": .number(32),
            "maxConnections": .number(64), "maxRequestIds": .number(65_536),
            "maxPendingRequests": .number(16), "maxQueuedBytes": .number(262_144),
          ]),
        ])
      case "status.get", "status.subscribe", "status.unsubscribe":
        _ = try fields(params, [])
        if method == "status.unsubscribe" {
          peer.subscribed = false
          result = .object([:])
        } else {
          checkPower()
          if method == "status.subscribe" { peer.subscribed = true }
          result = snapshot()
        }
      case "session.acquire", "session.update":
        guard !draining else { throw APIError("shutting_down", "daemon is draining") }
        guard phase != "degraded" else { throw APIError("not_ready", "recovery is required") }
        let p = try fields(
          params, method == "session.acquire" ? ["options"] : ["sessionId", "options"])
        let option = try options(p["options"]!)
        let key = peer.fd.value
        if method == "session.acquire" {
          guard sessions[key] == nil else {
            throw APIError("session_exists", "connection already owns a session")
          }
          guard sessions.count < 32 else { throw APIError("limit_exceeded", "too many sessions") }
        } else {
          guard let sessionID = p["sessionId"]?.stringValue else {
            throw APIError("invalid_params", "sessionId must be string")
          }
          guard sessions[key]?.id == sessionID else {
            throw APIError("session_not_owned", "session not owned")
          }
        }
        try checkLidBefore(option)
        if sessions.isEmpty {
          do {
            if try power.readDisabled() {
              throw APIError("power_conflict", "sleep already disabled")
            }
          } catch let error as APIError { throw error } catch {
            fail("power_failed", "\(error)")
            throw APIError("power_failed", "\(error)")
          }
        }
        let session = Owned(
          id: sessions[key]?.id ?? UUID().uuidString, peer: peer, options: option,
          created: sessions[key]?.created ?? timestamp())
        sessions[key] = session
        do {
          try apply()
          bump()
        } catch {
          fail("power_failed", "\(error)")
          throw APIError("power_failed", "\(error)")
        }
        result = .object(["sessionId": .string(session.id), "revision": .string(String(revision))])
      case "session.release":
        let p = try fields(params, ["sessionId"])
        guard let sessionID = p["sessionId"]?.stringValue else {
          throw APIError("invalid_params", "sessionId must be string")
        }
        if sessions[peer.fd.value]?.id == sessionID {
          end(peer.fd.value)
          do {
            try apply()
            bump()
          } catch {
            fail("recovery_failed", "\(error)")
            throw APIError("recovery_failed", "\(error)")
          }
        } else if !peer.ended.contains(sessionID) {
          throw APIError("session_not_owned", "session not owned")
        } else if phase == "degraded" {
          throw APIError("recovery_failed", "cleanup remains unconfirmed")
        }
        result = .object(["revision": .string(String(revision))])
      case "session.stopSessions", "admin.stopSessions":
        let isAdministrative = method == "admin.stopSessions"
        let p = try fields(params, isAdministrative ? ["sessionIds", "authorization"] : ["sessionIds"])
        guard let values = p["sessionIds"]?.arrayValue, !values.isEmpty, values.count <= 32 else {
          throw APIError("invalid_params", "sessionIds must contain 1–32 session IDs")
        }
        var requested = Set<String>()
        for value in values {
          guard let sessionID = value.stringValue, !sessionID.isEmpty, sessionID.utf8.count <= 128,
            !sessionID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            requested.insert(sessionID).inserted
          else { throw APIError("invalid_params", "sessionIds must contain distinct valid IDs") }
        }
        if isAdministrative {
          let authorization: Data?
          if p["authorization"] == .null {
            authorization = nil
          } else {
            guard let encoded = p["authorization"]?.stringValue,
              let decoded = DopaAuthorization.decodeExternalForm(encoded)
            else { throw APIError("invalid_params", "invalid authorization external form") }
            authorization = decoded
          }
          guard peer.uid == 0 || authorization.map(authorizationVerifier) == true else {
            throw APIError("permission_denied", "administrator authorization required")
          }
        }
        // Select only the confirmed IDs, so a later session on the same peer
        // can never be swept up by an old confirmation or repeated request.
        let targets = sessions.filter { requested.contains($0.value.id) }
        // ServicePeer.uid comes from the socket's kernel credentials. Check
        // the entire selection before changing anything, including for root.
        guard isAdministrative || targets.values.allSatisfy({ $0.peer.uid == peer.uid }) else {
          throw APIError("permission_denied", "sessions owned by another user require administrator authorization")
        }
        if !targets.isEmpty {
          do { try terminate("user_stopped", keys: Array(targets.keys)) } catch {
            // A management request never removes unspecified sessions, even
            // when applying the aggregate fails. Preserve the journal and
            // expose the failure; new acquire/update operations stay disabled.
            phase = "degraded"
            disabled = nil
            display = nil
            lastError = errorValue("recovery_failed", "\(error)")
            bump()
            throw APIError("recovery_failed", "\(error)")
          }
        } else if phase == "degraded" {
          throw APIError("recovery_failed", "cleanup remains unconfirmed")
        }
        result = .object([
          "revision": .string(String(revision)),
          "stoppedSessionIds": .array(targets.values.map(\.id).sorted().map(JSONValue.string)),
        ])
      case "admin.prepareShutdown":
        _ = try fields(params, [])
        guard peer.uid == 0 else { throw APIError("permission_denied", "root required") }
        do { try prepareShutdown() } catch { throw APIError("recovery_failed", "\(error)") }
        result = .object(["revision": .string(String(revision))])
      default: throw APIError("unknown_method", "unknown method")
      }
      return .object(["id": id, "result": result])
    } catch let error as APIError {
      return .object([
        "id": id, "error": errorValue(error.code, error.message, details: error.details),
      ])
    } catch { return .object(["id": id, "error": errorValue("invalid_request", "\(error)")]) }
  }
  private func end(_ key: Int32) {
    guard let session = sessions.removeValue(forKey: key) else { return }
    session.peer.ended.append(session.id)
    if session.peer.ended.count > 32 { session.peer.ended.removeFirst() }
  }
  private func apply() throws {
    if sessions.isEmpty {
      var failure: Error?
      do {
        try controls.releaseDisplay()
        display = false
      } catch {
        display = nil
        failure = error
      }
      do {
        if try state.pending() {
          try power.setDisabled(false)
          guard try !power.readDisabled() else { throw DopaError("restoration was not confirmed") }
          disabled = false
          if failure == nil { try state.clear() }
        } else {
          disabled = try power.readDisabled()
        }
      } catch {
        disabled = nil
        failure = failure ?? error
      }
      checked = timestamp()
      if let failure { throw failure }
      phase = draining ? "draining" : "idle"
    } else {
      if try !state.pending() { try Session.start(power: power, state: state) }
      disabled = try power.readDisabled()
      guard disabled == true else { throw DopaError("sleep setting changed unexpectedly") }
      let wantsDisplay = sessions.values.contains { $0.options.keepDisplayOn }
      if wantsDisplay && display != true { try controls.keepDisplayOn() }
      if !wantsDisplay && display != false { try controls.releaseDisplay() }
      display = wantsDisplay
      checked = timestamp()
      phase = "active"
    }
    lastError = .null
  }
  private func terminate(_ reason: String, keys: [Int32]) throws {
    let removed = keys.compactMap { sessions[$0] }
    for key in keys { end(key) }
    var failure: Error?
    do { try apply() } catch { failure = error }
    bump()
    for session in removed {
      events.append(
        (
          session.peer.fd.value,
          .object([
            "event": .string("session.ended"),
            "data": .object([
              "sessionId": .string(session.id), "reason": .string(reason),
              "cleanup": .string(failure == nil ? "confirmed" : "failed"),
              "revision": .string(String(revision)),
            ]),
          ])
        ))
    }
    if let failure { throw failure }
  }
  private func fail(_ code: String, _ message: String) {
    try? terminate("power_error", keys: Array(sessions.keys))
    phase = "degraded"
    lastError = errorValue(code, message)
    bump()
  }
  func disconnect(_ key: Int32) {
    guard sessions[key] != nil else { return }
    end(key)
    do {
      try apply()
      bump()
    } catch { fail("recovery_failed", "\(error)") }
  }
  func checkPower() {
    if phase == "degraded" {
      let previous = disabled
      disabled = try? power.readDisabled()
      checked = timestamp()
      if previous != disabled { bump() }
      return
    }
    do {
      let current = try power.readDisabled()
      if !sessions.isEmpty && !current { throw DopaError("sleep setting changed externally") }
      let altered = disabled != current
      disabled = current
      checked = timestamp()
      if altered { bump() }
    } catch {
      disabled = nil
      fail("power_failed", "\(error)")
    }
  }
  func checkLid() {
    let keys = sessions.filter { $0.value.options.stopOnLidClose }.map(\.key)
    guard !keys.isEmpty else { return }
    let reason: String
    do {
      guard try controls.lidClosed() else { return }
      reason = "lid_closed"
    } catch { reason = "lid_error" }
    do { try terminate(reason, keys: keys) } catch { fail("recovery_failed", "\(error)") }
  }

  func prepareShutdown() throws {
    draining = true
    do {
      try terminate("daemon_shutdown", keys: Array(sessions.keys))
      lastError = .null
    } catch {
      phase = "degraded"
      lastError = errorValue("recovery_failed", "\(error)")
      bump()
      throw error
    }
  }
}
