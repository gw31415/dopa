import CDopa
import Darwin
import DopaAuthorization
import DopaProtocol
import Foundation

public enum DaemonService {
  /// Delivers one pending `status.changed` broadcast, if any, to subscribed
  /// peers. The frame is encoded at most once and shared; when no peer
  /// subscribes, nothing is encoded and `snapshot()` (which re-reads power
  /// state) is not even built, so CLI-only acquire/release performs zero
  /// notification encodes. The pending change is still consumed because a
  /// later `status.subscribe` response already contains the current complete
  /// snapshot. The `encode` parameter exists so tests can count encodings;
  /// production passes `JSONWire.encode`.
  static func deliverBroadcast(
    engine: DaemonEngine,
    peers: [Int32: ServicePeer],
    encode: (JSONValue) throws -> Data = JSONWire.encode
  ) {
    guard engine.changed else { return }
    engine.changed = false
    let targets = peers.values.filter { $0.subscribed }
    guard !targets.isEmpty else { return }
    let event = JSONValue.object([
      "event": .string("status.changed"),
      "data": .object([
        "instanceId": .string(engine.instanceID), "revision": .string(String(engine.revision)),
        "snapshot": engine.snapshot(),
      ]),
    ])
    do {
      let shared = try encode(event)
      for peer in targets { peer.enqueueSnapshot(shared) }
    } catch {
      // Unreachable for engine-built events; keep enqueue's dead-marking.
      for peer in targets { peer.dead = true }
    }
  }

  /// Milliseconds until the next timer-driven work, for the run loop's poll()
  /// timeout: power recheck (only while peers exist), and each peer's hello /
  /// partial-frame deadline. Returns -1 when nothing is pending, so an idle daemon sleeps
  /// until socket or stop-pipe activity. Communication wakes poll() regardless
  /// of this timeout, and stop signals arrive through the stop self-pipe even
  /// when the timeout is infinite, so no deadline or notification is missed.
  static func pollTimeoutMilliseconds(
    now: Date, nextCheck: Date, peers: [Int32: ServicePeer]
  ) -> Int32 {
    var earliest: TimeInterval?
    func consider(_ date: Date) {
      let remaining = date.timeIntervalSince(now)
      if earliest == nil || remaining < earliest! { earliest = remaining }
    }
    if !peers.isEmpty { consider(nextCheck) }
    for peer in peers.values {
      if !peer.hello { consider(peer.created.addingTimeInterval(5)) }
      if let partial = peer.partialSince { consider(partial.addingTimeInterval(5)) }
    }
    guard let remaining = earliest else { return -1 }
    if remaining <= 0 { return 0 }
    // poll() takes whole milliseconds. Truncating a positive sub-millisecond
    // remainder to zero spins until the deadline, so round upward.
    return Int32(min((remaining * 1000).rounded(.up), Double(Int32.max)))
  }

  public static func run(
    statePath: String = "/var/db/dopa", socketPath: String = "/var/run/dopa/control.sock",
    allowedUID: uid_t, power: any Power, controls: any DisplayControls, requireRoot: Bool = true,
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
    func publish() {
      let events = engine.takeEvents()
      for (owner, event) in events { peers[owner]?.enqueue(event) }
      DaemonService.deliverBroadcast(engine: engine, peers: peers)
    }
    // Listener plus stop pipe plus at most 64 peers; backing storage is reused.
    var polls: [pollfd] = []
    polls.reserveCapacity(67)
    // Reused read work buffer; only the prefix written by each read() is read.
    var bytes = [UInt8](repeating: 0, count: 16_384)
    // Stop self-pipe: a signal makes it readable so poll() wakes immediately
    // even with an infinite computed timeout. The flag stays authoritative;
    // a missing pipe only falls back to bounded polling.
    let stopFD = dopa_stop_fd()
    var drainByte: UInt8 = 0
    while dopa_stop_requested() == 0 {
      let timeout = stopFD < 0 ? 50 : DaemonService.pollTimeoutMilliseconds(
        now: Date(), nextCheck: nextCheck, peers: peers)
      // Rebuild registrations from scratch so accept/close/FD reuse is reflected.
      polls.removeAll(keepingCapacity: true)
      polls.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0))
      if stopFD >= 0 {
        polls.append(pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0))
      }
      for peer in peers.values {
        polls.append(
          pollfd(
            fd: peer.fd.value, events: Int16(POLLIN) | (peer.isEmpty ? 0 : Int16(POLLOUT)),
            revents: 0))
      }
      let result = poll(&polls, nfds_t(polls.count), timeout)
      if result < 0 && errno != EINTR { throw systemError("poll daemon") }
      if polls[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
        throw DopaError("daemon listener failed")
      }
      var cursor = polls.dropFirst()
      if stopFD >= 0, let stopEntry = cursor.first, stopEntry.fd == stopFD {
        // Drain stop notifications; the loop condition re-checks the flag.
        // HUP/NVAL on our own pipe cannot occur; ignore them either way.
        if stopEntry.revents & Int16(POLLIN) != 0 {
          while Darwin.read(stopFD, &drainByte, 1) > 0 {}
        }
        cursor = cursor.dropFirst()
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
      for entry in cursor {
        guard let peer = peers[entry.fd] else { continue }
        if entry.revents & Int16(POLLIN | POLLHUP) != 0 && !peer.closing {
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
        if !peer.isEmpty {
          peer.flush { raw in Darwin.write(entry.fd, raw.baseAddress, raw.count) }
        }
        if entry.revents & Int16(POLLERR | POLLNVAL) != 0 { peer.dead = true }
      }
      let now = Date()
      for (id, peer) in peers {
        if (!peer.hello && now.timeIntervalSince(peer.created) > 5)
          || (peer.partialSince.map { now.timeIntervalSince($0) > 5 } ?? false)
          || (peer.closing && peer.isEmpty) || peer.dead
        {
          engine.disconnect(id)
          peers.removeValue(forKey: id)
        }
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
      _ = peer.writeSlice { raw in Darwin.write(peer.fd.value, raw.baseAddress, raw.count) }
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
  // Undelivered bytes are output[outputOffset...]; the drained prefix is
  // compacted or dropped so partial writes do not copy on every send.
  var output = Data()
  var outputOffset = 0
  // Length of the trailing broadcast snapshot frame, if the output tail is
  // exactly one fully unsent snapshot that a newer broadcast may replace.
  // Any other append, send, or reset invalidates it (see didSend/enqueue).
  var pendingSnapshotBytes: Int?
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
  /// Bytes queued but not yet delivered; the cap accounting uses this, not
  /// output.count, which also covers the drained prefix.
  var queuedBytes: Int { output.count - outputOffset }
  var isEmpty: Bool { outputOffset == output.count }
  /// Hands only undelivered bytes to a write call.
  func writeSlice(_ write: (UnsafeRawBufferPointer) -> Int) -> Int {
    let offset = outputOffset
    guard output.count > offset else { return 0 }
    return output.withUnsafeBytes { raw in
      write(UnsafeRawBufferPointer(rebasing: raw[offset...]))
    }
  }
  /// Records a successful partial write and reclaims drained storage.
  func didSend(_ count: Int) {
    guard count > 0 else { return }
    outputOffset += count
    if outputOffset == output.count {
      // Full drain: reset so queued capacity is released.
      output = Data()
      outputOffset = 0
      pendingSnapshotBytes = nil
    } else if outputOffset > 65_536 {
      // Compact the drained prefix instead of copying on every partial write.
      // A tracked trailing snapshot shifts with it; its length stays valid.
      output.removeFirst(outputOffset)
      outputOffset = 0
    }
  }
  /// Attempts one non-blocking write and updates queue state. Recoverable
  /// kernel backpressure and signal interruption leave the exact unsent slice
  /// intact for the next POLLOUT wakeup.
  @discardableResult
  func flush(
    _ write: (UnsafeRawBufferPointer) -> Int,
    errorCode: () -> Int32 = { errno }
  ) -> Int {
    let sent = writeSlice(write)
    if sent > 0 {
      didSend(sent)
    } else if sent < 0 {
      let code = errorCode()
      if code != EAGAIN && code != EINTR { dead = true }
    }
    return sent
  }
  func enqueue(_ value: JSONValue) {
    guard !dead else { return }
    guard let data = try? JSONWire.encode(value), queuedBytes + data.count <= 262_144 else {
      dead = true
      return
    }
    // Anything appended after a tracked snapshot breaks the exact-tail
    // shape, so later broadcasts keep both frames in order.
    pendingSnapshotBytes = nil
    output.append(data)
  }
  /// Broadcast fast path: append bytes already encoded by the publisher.
  /// Coalesces with a previous broadcast snapshot when that frame is still
  /// the complete, fully unsent tail: the older snapshot is dropped and only
  /// the newest is delivered. Anything else in between (a response, a
  /// session.ended, or an already-sent prefix) disables coalescing for that
  /// round and both frames are kept in order, so causal order is never
  /// rewritten and partially sent bytes are never replaced.
  func enqueueSnapshot(_ data: Data) {
    guard !dead else { return }
    if let old = pendingSnapshotBytes,
      outputOffset <= output.count - old
    {
      output.removeLast(old)
      pendingSnapshotBytes = nil
    }
    guard queuedBytes + data.count <= 262_144 else {
      dead = true
      return
    }
    output.append(data)
    pendingSnapshotBytes = data.count
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
  struct SessionOptions {
    let keepDisplayOn: Bool
  }

  struct Owned {
    let id: String
    let peer: ServicePeer
    var options: SessionOptions
    let created: String
  }
  let state: State
  let power: any Power
  let controls: any DisplayControls
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
    state: State, power: any Power, controls: any DisplayControls,
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
  // Reused instead of allocating per timestamp() call; DaemonEngine is confined
  // to the daemon's single serial run-loop thread (DaemonService.run).
  // ISO8601DateFormatter is locale-independent (fixed en_US_POSIX-equivalent
  // output); the zero-offset timezone is set explicitly to pin "Z" output.
  private let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()
  private func timestamp() -> String { timestampFormatter.string(from: Date()) }
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
  private func optionsValue(_ options: SessionOptions) -> JSONValue {
    .object(["keepDisplayOn": .bool(options.keepDisplayOn)])
  }
  private func fields(_ value: JSONValue, _ keys: Set<String>) throws -> [String: JSONValue] {
    guard let object = value.objectValue, Set(object.keys) == keys else {
      throw APIError("invalid_params", "unexpected or missing fields")
    }
    return object
  }
  private func options(_ value: JSONValue) throws -> SessionOptions {
    let object = try fields(value, ["keepDisplayOn"])
    guard let display = object["keepDisplayOn"]?.boolValue else {
      throw APIError("invalid_params", "keepDisplayOn must be boolean")
    }
    return SessionOptions(keepDisplayOn: display)
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
          "apiVersion": .number(1), "daemonVersion": .string(DopaProtocol.appVersion),
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
