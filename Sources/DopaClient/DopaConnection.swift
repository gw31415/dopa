import Darwin
import DopaProtocol
import Foundation

public struct DopaRemoteError: Error, Equatable, Sendable, CustomStringConvertible {
  public let code: String
  public let message: String
  public let details: JSONValue?

  public init(code: String, message: String, details: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }

  public var description: String {
    "\(code): \(message)"
  }
}

/// The error type used for failures in the local client or wire protocol.
public enum DopaClientError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidClientName
  case invalidSocketPath
  case socketPathMissing
  case unsafeSocketPath(String)
  case socketFailure(String)
  case invalidTimeout
  case timedOut(String)
  case connectionClosed
  case protocolViolation(String)

  public var description: String {
    switch self {
    case .invalidClientName:
      return "client name must be 1–128 UTF-8 bytes without control characters"
    case .invalidSocketPath:
      return "invalid Unix socket path"
    case .socketPathMissing:
      return "Dopa daemon socket is unavailable"
    case .unsafeSocketPath(let message):
      return "unsafe Dopa daemon socket: \(message)"
    case .socketFailure(let message):
      return "Dopa daemon socket: \(message)"
    case .invalidTimeout:
      return "timeout must be a finite, non-negative duration"
    case .timedOut(let operation):
      return "timed out waiting for Dopa daemon (\(operation))"
    case .connectionClosed:
      return "Dopa daemon connection closed"
    case .protocolViolation(let message):
      return "Dopa daemon protocol error: \(message)"
    }
  }
}

/// A synchronous, serialized client for Dopa's `dopa-daemon` NDJSON API.
///
/// The connection owns any session acquired through it. Closing the socket,
/// including an explicit timeout, lets the daemon release that session.
public final class DopaConnection {
  public typealias RemoteError = DopaRemoteError

  public static let defaultSocketPath = "/var/run/dopa/control.sock"
  private static let initialReadChunkSize = 4 * 1024
  private static let maximumReadChunkSize = 16 * 1024

  private var descriptor: Int32
  private var lineBuffer = JSONLineBuffer()
  // Scratch space allocated on the first socket read and then reused by every
  // read in `nextMessage`. All reads are serialized by `lock`, so one buffer
  // can serve the connection.
  // Freshly read bytes are copied out (Data init) before the next read;
  // this buffer never aliases `lineBuffer` or `decodedMessages`.
  private var readBuffer: [UInt8] = []
  // `decodedMessages` and `events` act as FIFO queues: entries before the
  // head index are already consumed. Dequeueing advances the head instead of
  // shifting the array, and the dead prefix is dropped in batches by the
  // dequeue helpers below so retained storage stays bounded.
  private var decodedMessages: [JSONValue] = []
  private var decodedHead = 0
  private var events: [JSONValue] = []
  private var eventsHead = 0
  private var nextRequestNumber: UInt64 = 1
  private var closed = false
  private let lock = NSLock()
  /// Independently synchronized because receive holds `lock` while polling.
  /// Its self-pipe is allocated only if a receive actually needs to wait.
  private let receiveWakeup = ReceiveWakeup()

  public let path: String
  public let clientName: String
  /// Negotiated hello metadata. Unknown capabilities remain available to callers.
  public private(set) var hello: JSONValue = .null

  public var capabilities: Set<String> {
    guard case .array(let values) = hello.objectValue?["capabilities"] else { return [] }
    return Set(values.compactMap(\.stringValue))
  }

  public init(
    path: String = DopaConnection.defaultSocketPath,
    requireRoot: Bool = true,
    clientName: String = "dopa"
  ) throws {
    guard Self.validClientName(clientName) else { throw DopaClientError.invalidClientName }
    let fd = try Self.open(path: path, requireRoot: requireRoot)
    self.descriptor = fd
    self.path = path
    self.clientName = clientName

    do {
      let hello = try performRequest(
        method: "hello",
        params: .object([
          "apiVersion": .number(Double(DopaProtocol.apiVersion)),
          "client": .object([
            "name": .string(clientName),
            "version": .string(DopaProtocol.appVersion),
          ]),
        ]),
        timeout: 5
      )
      try Self.validateHello(hello)
      self.hello = hello
    } catch {
      closeUnlocked()
      throw error
    }
  }

  deinit {
    closeUnlocked()
  }

  /// Sends one request and returns its result value.
  ///
  /// Events received while waiting for the response are retained for the
  /// next call to `receive(timeout:)`.
  public func request(
    method: String,
    params: JSONValue = .object([:]),
    timeout: TimeInterval = 10
  ) throws -> JSONValue {
    lock.lock()
    defer { lock.unlock() }
    return try performRequest(method: method, params: params, timeout: timeout)
  }

  /// Returns the next queued or incoming event, or nil when the timeout
  /// expires. A timeout here leaves the connection open for later polling.
  ///
  /// This overload preserves the original public API and method symbol.
  public func receive(timeout: TimeInterval) throws -> JSONValue? {
    try receive(timeout: timeout, interruptible: false)
  }

  /// Returns the next queued or incoming event, allowing a concurrent
  /// `interruptReceive()` to end the wait as an early nil result. Explicit
  /// close also wakes both this overload and the original overload promptly.
  /// Request paths never observe receive interrupts.
  public func receive(timeout: TimeInterval, interruptible: Bool) throws -> JSONValue? {
    lock.lock()
    defer { lock.unlock() }
    do {
      let deadline = try makeDeadline(timeout: timeout)
      if eventsHead < events.count { return dequeueEvent() }

      while true {
        let message = try nextMessage(
          deadline: deadline, receiveWait: true, interruptible: interruptible)
        guard let object = message.objectValue else {
          throw closeAfterProtocolError("event or response must be an object")
        }
        if object["event"] != nil {
          try Self.validateEvent(object)
          return message
        }
        throw closeAfterProtocolError("unexpected response while no request is pending")
      }
    } catch is ReceiveInterrupted {
      return nil
    } catch let error as DopaClientError {
      if case .timedOut(let operation) = error, operation == "read" { return nil }
      closeUnlocked()
      throw error
    } catch {
      closeUnlocked()
      throw error
    }
  }

  public func close() {
    // `receive` holds the operation lock throughout poll. Publish the close
    // first so that wait wakes before this method acquires that lock.
    receiveWakeup.beginClose()
    lock.lock()
    closeUnlocked()
    lock.unlock()
  }

  /// Wakes a thread currently blocked in an interruptible `receive` so a
  /// queued request (or shutdown) does not wait out the poll budget. The
  /// woken wait returns nil promptly; socket data is never lost and no error
  /// is produced. Safe to call any time, including with no waiter or after
  /// close. Request paths are never interruptible, so this can only ever
  /// shorten a transport poll, never fail a request.
  public func interruptReceive() {
    receiveWakeup.interrupt()
  }

  /// The underlying socket file descriptor, for waiting on readability with
  /// poll/select alongside other event sources only. Never close, shut down,
  /// read, or write it directly; use request()/receive()/close() instead.
  /// Reads as -1 once the connection is closed.
  public var socketDescriptor: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return descriptor
  }

  // MARK: - Serialized request implementation

  private func performRequest(
    method: String,
    params: JSONValue,
    timeout: TimeInterval
  ) throws -> JSONValue {
    guard !closed else { throw DopaClientError.connectionClosed }
    guard !method.isEmpty, method.utf8.count <= 128,
      !method.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else {
      throw DopaClientError.protocolViolation("invalid method")
    }
    let deadline = try makeDeadline(timeout: timeout)
    let id = String(nextRequestNumber)
    nextRequestNumber &+= 1
    let request = JSONValue.object([
      "id": .string(id),
      "method": .string(method),
      "params": params,
    ])
    // Encoding is local validation. If the caller supplied an invalid or
    // oversized value, no request was sent and the live session can remain
    // owned by this connection.
    let encoded = try JSONWire.encode(request)

    do {
      try send(encoded, deadline: deadline)
      while true {
        let message = try nextMessage(deadline: deadline)
        guard let object = message.objectValue else {
          throw closeAfterProtocolError("response must be an object")
        }
        if object["event"] != nil {
          try Self.validateEvent(object)
          // Count only queued (unconsumed) events; entries before eventsHead
          // were already handed out and must not tighten the limit.
          guard events.count - eventsHead < 128 else {
            throw closeAfterProtocolError("event queue is full")
          }
          events.append(message)
          continue
        }
        guard let responseID = object["id"]?.stringValue else {
          throw closeAfterProtocolError("response id is missing or not a string")
        }
        guard responseID == id else {
          throw closeAfterProtocolError("response id does not match request")
        }
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
          throw closeAfterProtocolError("response must contain exactly one of result or error")
        }
        if hasError {
          throw try Self.remoteError(from: object["error"]!)
        }
        return object["result"]!
      }
    } catch let error as DopaRemoteError {
      // A declared remote error is a response and the connection remains
      // usable for a subsequent request.
      throw error
    } catch {
      // A timeout or malformed/disconnected stream invalidates the session's
      // ownership. Closing here makes that fact visible to the daemon.
      closeUnlocked()
      throw error
    }
  }

  private func send(_ data: Data, deadline: UInt64) throws {
    var sent = 0
    while sent < data.count {
      try wait(for: Int16(POLLOUT), deadline: deadline, operation: "write")
      let result = data.withUnsafeBytes { buffer in
        Darwin.write(
          descriptor,
          buffer.baseAddress!.advanced(by: sent),
          buffer.count - sent)
      }
      if result > 0 {
        sent += result
      } else if result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
        continue
      } else if result < 0 {
        throw DopaClientError.socketFailure(String(cString: strerror(errno)))
      } else {
        throw DopaClientError.connectionClosed
      }
    }
  }

  // Dequeueing advances a head index instead of calling removeFirst(), so a
  // single consume never shifts the remaining elements. The consumed prefix
  // is compacted (dropped from storage) once it exceeds 64 entries or half
  // of the remaining storage, which keeps the dead prefix small while making
  // the compaction copy rare. Order stays FIFO and capacity cannot grow
  // without bound.
  private func dequeueEvent() -> JSONValue {
    let value = events[eventsHead]
    eventsHead += 1
    if eventsHead > 64 || eventsHead * 2 > events.count {
      events.removeFirst(eventsHead)
      eventsHead = 0
    }
    return value
  }

  private func dequeueDecodedMessage() -> JSONValue {
    let value = decodedMessages[decodedHead]
    decodedHead += 1
    if decodedHead > 64 || decodedHead * 2 > decodedMessages.count {
      decodedMessages.removeFirst(decodedHead)
      decodedHead = 0
    }
    return value
  }

  private func nextMessage(
    deadline: UInt64, receiveWait: Bool = false, interruptible: Bool = false
  ) throws -> JSONValue {
    if decodedHead < decodedMessages.count { return dequeueDecodedMessage() }

    while true {
      try wait(
        for: Int16(POLLIN), deadline: deadline, operation: "read",
        receiveWait: receiveWait, interruptible: interruptible)
      // Most control frames fit in 4 KiB. Grow toward 16 KiB only after a
      // full read so ordinary connections retain less scratch memory while
      // large frames still amortize their system calls.
      if readBuffer.isEmpty {
        readBuffer = [UInt8](repeating: 0, count: Self.initialReadChunkSize)
      }
      let count = readBuffer.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
      }
      if count > 0 {
        // The Data initializer copies the read prefix out of the scratch
        // buffer, so reusing readBuffer below cannot alias lineBuffer or
        // the decoded messages derived from it.
        let chunk = Data(readBuffer[0..<count])
        if count == readBuffer.count, readBuffer.count < Self.maximumReadChunkSize {
          readBuffer = [UInt8](
            repeating: 0,
            count: min(readBuffer.count * 2, Self.maximumReadChunkSize))
        }
        let values = try JSONLineBufferData.append(&lineBuffer, chunk)
        decodedMessages.append(contentsOf: values)
        if decodedHead < decodedMessages.count { return dequeueDecodedMessage() }
        continue
      }
      if count == 0 {
        closeUnlocked()
        throw DopaClientError.connectionClosed
      }
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      throw DopaClientError.socketFailure(String(cString: strerror(errno)))
    }
  }

  private func wait(
    for events: Int16, deadline: UInt64, operation: String,
    receiveWait: Bool = false, interruptible: Bool = false
  ) throws {
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { throw DopaClientError.timedOut(operation) }
      let remaining = deadline - now
      let milliseconds = min(
        UInt64(Int32.max),
        max(UInt64(1), (remaining + 999_999) / 1_000_000))
      if !receiveWait {
        var pollfd = Darwin.pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&pollfd, 1, Int32(milliseconds))
        if result > 0 {
          if pollfd.revents & Int16(POLLNVAL | POLLERR) != 0 {
            throw DopaClientError.connectionClosed
          }
          if pollfd.revents & events != 0 || pollfd.revents & Int16(POLLHUP) != 0 { return }
          continue
        }
        if result == 0 { throw DopaClientError.timedOut(operation) }
        if errno == EINTR { continue }
        throw DopaClientError.socketFailure(String(cString: strerror(errno)))
      }

      let preparation = try receiveWakeup.prepareWait()
      switch preparation {
      case .wake(let reason):
        if reason == .closing || interruptible { throw ReceiveInterrupted() }
        // A transient interrupt is only meaningful to the opt-in overload.
        // The original receive(timeout:) keeps waiting until data or timeout.
        continue
      case .descriptor:
        break
      }
      guard case .descriptor(let pipeRead) = preparation else { continue }
      var polls = [
        Darwin.pollfd(fd: descriptor, events: events, revents: 0),
        Darwin.pollfd(fd: pipeRead, events: Int16(POLLIN), revents: 0),
      ]
      let result = polls.withUnsafeMutableBufferPointer {
        Darwin.poll($0.baseAddress!, 2, Int32(milliseconds))
      }
      receiveWakeup.finishWait()
      if result > 0 {
        let wakeReason = polls[1].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0
          ? receiveWakeup.consumeWake() : nil
        // Explicit close takes precedence over socket data. The closer is
        // waiting for this operation lock and will dispose the descriptor as
        // soon as the receive returns.
        if wakeReason == .closing { throw ReceiveInterrupted() }
        if polls[0].revents & Int16(POLLNVAL | POLLERR) != 0 {
          throw DopaClientError.connectionClosed
        }
        if polls[0].revents & events != 0 || polls[0].revents & Int16(POLLHUP) != 0 { return }
        // An interrupt with no socket activity ends this wait promptly. The
        // caller treats it like a timeout (early empty return), never as an
        // error, so socket data is never lost and no error type changes.
        if wakeReason == .interrupt && interruptible {
          throw ReceiveInterrupted()
        }
        continue
      }
      if result == 0 { throw DopaClientError.timedOut(operation) }
      if errno == EINTR { continue }
      throw DopaClientError.socketFailure(String(cString: strerror(errno)))
    }
  }

  private func makeDeadline(timeout: TimeInterval) throws -> UInt64 {
    guard timeout.isFinite, timeout >= 0 else {
      throw DopaClientError.invalidTimeout
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let duration = timeout * 1_000_000_000
    guard duration < Double(UInt64.max) else { return UInt64.max }
    let nanos = UInt64(duration)
    return now.addingReportingOverflow(nanos).overflow ? UInt64.max : now + nanos
  }

  private func closeAfterProtocolError(_ message: String) -> DopaClientError {
    closeUnlocked()
    return .protocolViolation(message)
  }

  private func closeUnlocked() {
    guard !closed else { return }
    closed = true
    Darwin.close(descriptor)
    descriptor = -1
    receiveWakeup.finalizeClose()
    // Release state that no public API can observe once the descriptor is
    // gone, while keeping everything that is still retrievable:
    // - `lineBuffer` holds at most one partial frame. No read can complete it
    //   after close, so its bytes are unreachable through request/receive.
    // - `readBuffer` is pure scratch. It is rebuilt lazily in nextMessage()
    //   if a half-closed state ever reaches a read, so releasing it here is
    //   safe and drops its adaptive 4–16 KiB allocation.
    // - Consumed prefixes of `events` / `decodedMessages` are compacted so
    //   already-handed-out payloads are released; unread elements stay in
    //   order. receive() drains both after close, exactly as before.
    // The `closed` guard makes this release run at most once across close(),
    // deinit, repeated close, and the error paths, all serialized by `lock`.
    lineBuffer = JSONLineBuffer()
    readBuffer.removeAll(keepingCapacity: false)
    if eventsHead > 0 {
      events.removeFirst(eventsHead)
      eventsHead = 0
    }
    if events.isEmpty { events.removeAll(keepingCapacity: false) }
    if decodedHead > 0 {
      decodedMessages.removeFirst(decodedHead)
      decodedHead = 0
    }
    if decodedMessages.isEmpty { decodedMessages.removeAll(keepingCapacity: false) }
  }

  // MARK: - Response validation

  private static func validateEvent(_ object: [String: JSONValue]) throws {
    guard object["event"]?.stringValue != nil,
      object.keys.contains("data")
      && object["id"] == nil
      && object["result"] == nil
      && object["error"] == nil
    else {
      throw DopaClientError.protocolViolation("malformed event")
    }
  }

  private static func remoteError(from value: JSONValue) throws -> DopaRemoteError {
    guard let object = value.objectValue,
      let code = object["code"]?.stringValue,
      let message = object["message"]?.stringValue
    else {
      throw DopaClientError.protocolViolation("malformed error response")
    }
    return DopaRemoteError(code: code, message: message, details: object["details"])
  }

  private static func validateHello(_ value: JSONValue) throws {
    guard let object = value.objectValue,
      let apiVersion = object["apiVersion"]?.numberValue,
      apiVersion == Double(DopaProtocol.apiVersion)
    else {
      throw DopaClientError.protocolViolation("hello response has an unsupported API version")
    }
  }

  private static func validClientName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 128
      && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
  }

  // MARK: - Unix domain socket setup

  private static func open(path: String, requireRoot: Bool) throws -> Int32 {
    let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
    guard !path.isEmpty, !path.utf8.contains(0),
      path.utf8.count < MemoryLayout<sockaddr_un>.size - pathOffset
    else {
      throw DopaClientError.invalidSocketPath
    }
    if requireRoot { try validateSecurePath(path) }
    else {
      var info = stat()
      guard lstat(path, &info) == 0 else {
        if errno == ENOENT { throw DopaClientError.socketPathMissing }
        throw DopaClientError.socketFailure(String(cString: strerror(errno)))
      }
      guard info.st_mode & S_IFMT == S_IFSOCK else {
        throw DopaClientError.unsafeSocketPath("endpoint is not a socket")
      }
    }

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DopaClientError.socketFailure(String(cString: strerror(errno))) }
    var closeOnFailure = true
    defer { if closeOnFailure { Darwin.close(fd) } }

    let descriptorFlags = fcntl(fd, F_GETFD)
    guard descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
      throw DopaClientError.socketFailure(String(cString: strerror(errno)))
    }
    let statusFlags = fcntl(fd, F_GETFL)
    guard statusFlags >= 0, fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
      throw DopaClientError.socketFailure(String(cString: strerror(errno)))
    }
    var noSigPipe: Int32 = 1
    _ = withUnsafePointer(to: &noSigPipe) {
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }

    var address = try makeAddress(path: path)
    let addressLength = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + path.utf8.count + 1)
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, addressLength)
      }
    }
    if connectResult != 0 && errno != EINPROGRESS {
      if errno == ENOENT || errno == ECONNREFUSED { throw DopaClientError.socketPathMissing }
      throw DopaClientError.socketFailure(String(cString: strerror(errno)))
    }
    if connectResult != 0 {
      let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
      try waitForConnection(fd: fd, deadline: deadline)
    }

    if requireRoot {
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(fd, &uid, &gid) == 0 else {
        throw DopaClientError.socketFailure("cannot inspect daemon peer")
      }
      guard uid == 0 else { throw DopaClientError.unsafeSocketPath("daemon peer is not root") }
    }
    closeOnFailure = false
    return fd
  }

  private static func waitForConnection(fd: Int32, deadline: UInt64) throws {
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { throw DopaClientError.timedOut("connect") }
      let remaining = min(UInt64(Int32.max) * 1_000_000, deadline - now)
      var descriptor = Darwin.pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      let result = Darwin.poll(&descriptor, 1, Int32(max(UInt64(1), (remaining + 999_999) / 1_000_000)))
      if result < 0 {
        if errno == EINTR { continue }
        throw DopaClientError.socketFailure(String(cString: strerror(errno)))
      }
      if result == 0 { throw DopaClientError.timedOut("connect") }
      var status: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &length) == 0 else {
        throw DopaClientError.socketFailure(String(cString: strerror(errno)))
      }
      guard status == 0 else {
        if status == ENOENT || status == ECONNREFUSED { throw DopaClientError.socketPathMissing }
        throw DopaClientError.socketFailure(String(cString: strerror(status)))
      }
      return
    }
  }

  private static func makeAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    var address = sockaddr_un()
    let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
    address.sun_len = UInt8(offset + bytes.count + 1)
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { pathPointer in
        for (index, byte) in bytes.enumerated() {
          pathPointer[index] = CChar(bitPattern: byte)
        }
        pathPointer[bytes.count] = 0
      }
    }
    return address
  }

  private static func validateSecurePath(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT { throw DopaClientError.socketPathMissing }
      throw DopaClientError.socketFailure(String(cString: strerror(errno)))
    }
    guard info.st_mode & S_IFMT == S_IFSOCK else {
      throw DopaClientError.unsafeSocketPath("endpoint is not a socket")
    }
    guard info.st_uid == 0 else {
      throw DopaClientError.unsafeSocketPath("endpoint is not root-owned")
    }

    let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard let resolvedPointer = realpath(parentPath, nil) else {
      throw DopaClientError.unsafeSocketPath("cannot resolve endpoint directory")
    }
    defer { free(resolvedPointer) }
    let resolved = String(cString: resolvedPointer)
    var directory = stat()
    guard lstat(resolved, &directory) == 0,
      directory.st_mode & S_IFMT == S_IFDIR,
      directory.st_uid == 0,
      directory.st_mode & 0o022 == 0
    else {
      throw DopaClientError.unsafeSocketPath("endpoint directory is not root-owned and private")
    }
  }
}

private enum JSONLineBufferData {
  static func append(_ buffer: inout JSONLineBuffer, _ data: Data) throws -> [JSONValue] {
    try buffer.append(data)
  }
}

/// A lazily allocated self-pipe used only by event receives. Its descriptor
/// lifetime has a lock separate from `DopaConnection.lock`, allowing close to
/// wake a receiver while that receiver owns the connection's operation lock.
/// All writes and closes are serialized, and the write end is retired before
/// the read end, so a concurrent interrupt cannot hit SIGPIPE or a reused FD.
private final class ReceiveWakeup {
  enum WakeReason: Equatable {
    case interrupt
    case closing
  }

  enum Preparation {
    case descriptor(Int32)
    case wake(WakeReason)
  }

  private let lock = NSLock()
  private var readDescriptor: Int32 = -1
  private var writeDescriptor: Int32 = -1
  private var waiting = false
  private var pendingInterrupt = false
  private var closing = false

  func prepareWait() throws -> Preparation {
    lock.lock()
    defer { lock.unlock() }
    if closing { return .wake(.closing) }
    if pendingInterrupt {
      pendingInterrupt = false
      drainLocked()
      return .wake(.interrupt)
    }
    try createPipeLocked()
    waiting = true
    return .descriptor(readDescriptor)
  }

  func finishWait() {
    lock.lock()
    waiting = false
    lock.unlock()
  }

  func consumeWake() -> WakeReason? {
    lock.lock()
    defer { lock.unlock() }
    drainLocked()
    if closing { return .closing }
    guard pendingInterrupt else { return nil }
    pendingInterrupt = false
    return .interrupt
  }

  func interrupt() {
    lock.lock()
    defer { lock.unlock() }
    guard !closing else { return }
    pendingInterrupt = true
    if waiting { signalLocked() }
  }

  func beginClose() {
    lock.lock()
    defer { lock.unlock() }
    guard !closing else { return }
    closing = true
    pendingInterrupt = false
    if waiting { signalLocked() }
  }

  func finalizeClose() {
    lock.lock()
    closing = true
    waiting = false
    pendingInterrupt = false
    let write = writeDescriptor
    let read = readDescriptor
    writeDescriptor = -1
    readDescriptor = -1
    // Keep the read end alive until no writer can retain the old descriptor.
    // `interrupt()` uses this same lock, so closing the writer first prevents
    // both SIGPIPE and a write after descriptor-number reuse.
    if write >= 0 { Darwin.close(write) }
    if read >= 0 { Darwin.close(read) }
    lock.unlock()
  }

  private func createPipeLocked() throws {
    guard readDescriptor < 0 else { return }
    var descriptors = [Int32](repeating: -1, count: 2)
    guard descriptors.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
      throw DopaClientError.socketFailure(String(cString: strerror(errno)))
    }
    for descriptor in descriptors {
      let descriptorFlags = fcntl(descriptor, F_GETFD)
      let statusFlags = fcntl(descriptor, F_GETFL)
      guard descriptorFlags >= 0,
        fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
        statusFlags >= 0,
        fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
      else {
        let failure = errno
        for open in descriptors where open >= 0 { Darwin.close(open) }
        throw DopaClientError.socketFailure(String(cString: strerror(failure)))
      }
    }
    readDescriptor = descriptors[0]
    writeDescriptor = descriptors[1]
  }

  private func signalLocked() {
    guard writeDescriptor >= 0 else { return }
    var byte: UInt8 = 1
    while Darwin.write(writeDescriptor, &byte, 1) < 0 {
      if errno == EINTR { continue }
      // EAGAIN means the pipe already contains a wake byte. Other failures
      // are impossible under the synchronized lifetime contract, and the
      // pending flag still preserves an interrupt before the next wait.
      break
    }
  }

  private func drainLocked() {
    guard readDescriptor >= 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 64)
    while bytes.withUnsafeMutableBytes({
      Darwin.read(readDescriptor, $0.baseAddress!, $0.count)
    }) > 0 {}
  }
}

/// Thrown only inside a receive wait after an opted-in interrupt or explicit
/// close. `receive` converts it to an early nil return; it never escapes to
/// callers or closes the connection itself.
private struct ReceiveInterrupted: Error {}

private extension JSONValue {
  var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }
}

public typealias RemoteError = DopaRemoteError
