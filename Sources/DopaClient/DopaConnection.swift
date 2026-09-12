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
      return "dopa daemon socket is unavailable"
    case .unsafeSocketPath(let message):
      return "unsafe dopa daemon socket: \(message)"
    case .socketFailure(let message):
      return "dopa daemon socket: \(message)"
    case .invalidTimeout:
      return "timeout must be a finite, non-negative duration"
    case .timedOut(let operation):
      return "timed out waiting for dopa daemon (\(operation))"
    case .connectionClosed:
      return "dopa daemon connection closed"
    case .protocolViolation(let message):
      return "dopa daemon protocol error: \(message)"
    }
  }
}

/// A synchronous, serialized client for dopa-daemon's NDJSON API.
///
/// The connection owns any session acquired through it. Closing the socket,
/// including an explicit timeout, lets the daemon release that session.
public final class DopaConnection {
  public typealias RemoteError = DopaRemoteError

  public static let defaultSocketPath = "/var/run/dopa/control.sock"

  private var descriptor: Int32
  private var lineBuffer = JSONLineBuffer()
  private var decodedMessages: [JSONValue] = []
  private var events: [JSONValue] = []
  private var nextRequestNumber: UInt64 = 1
  private var closed = false
  private let lock = NSLock()

  public let path: String
  public let clientName: String

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
            "version": .string(DopaProtocol.clientVersion),
          ]),
        ]),
        timeout: 5
      )
      try Self.validateHello(hello)
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
  public func receive(timeout: TimeInterval) throws -> JSONValue? {
    lock.lock()
    defer { lock.unlock() }
    do {
      let deadline = try makeDeadline(timeout: timeout)
      if !events.isEmpty { return events.removeFirst() }

      while true {
        let message = try nextMessage(deadline: deadline)
        guard let object = message.objectValue else {
          throw closeAfterProtocolError("event or response must be an object")
        }
        if object["event"] != nil {
          try Self.validateEvent(object)
          return message
        }
        throw closeAfterProtocolError("unexpected response while no request is pending")
      }
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
    lock.lock()
    closeUnlocked()
    lock.unlock()
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
          guard events.count < 128 else {
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

  private func nextMessage(deadline: UInt64) throws -> JSONValue {
    if !decodedMessages.isEmpty { return decodedMessages.removeFirst() }

    while true {
      try wait(for: Int16(POLLIN), deadline: deadline, operation: "read")
      var bytes = [UInt8](repeating: 0, count: 16 * 1024)
      let count = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
      }
      if count > 0 {
        let values = try JSONLineBufferData.append(&lineBuffer, Data(bytes[0..<count]))
        decodedMessages.append(contentsOf: values)
        if !decodedMessages.isEmpty { return decodedMessages.removeFirst() }
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

  private func wait(for events: Int16, deadline: UInt64, operation: String) throws {
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { throw DopaClientError.timedOut(operation) }
      let remaining = deadline - now
      let milliseconds = min(
        UInt64(Int32.max),
        max(UInt64(1), (remaining + 999_999) / 1_000_000))
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

private extension JSONValue {
  var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }
}

public typealias RemoteError = DopaRemoteError
