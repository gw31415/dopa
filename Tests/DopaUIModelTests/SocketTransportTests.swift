import Darwin
import DopaProtocol
import Foundation
import XCTest

@testable import DopaUIModel

final class SocketTransportTests: XCTestCase {
  func testCloseWakesBlockedPollPromptly() async throws {
    let server = try TransportSocketFixture { client in
      let hello = try XCTUnwrap(try readTransportFrame(client))
      try sendTransportFrame(
        .object([
          "id": hello["id"]!,
          "result": .object([
            "apiVersion": .number(1),
            "capabilities": .array([]),
          ]),
        ]), to: client)
      let subscribe = try XCTUnwrap(try readTransportFrame(client))
      XCTAssertEqual(subscribe["method"]?.stringValue, "status.subscribe")
      try sendTransportFrame(
        .object(["id": subscribe["id"]!, "result": idleTransportSnapshot()]), to: client)
      while try readTransportFrame(client) != nil {}
    }
    defer { server.stop() }
    let transport = SocketTransport(path: server.path, requireRoot: false)
    _ = try await transport.connect()

    let poll = Task { try await transport.poll() }
    // Give the serial socket queue time to enter its 30-second receive. The
    // close path is also correct if it wins before receive starts.
    try await Task.sleep(nanoseconds: 100_000_000)
    let started = Date()
    await transport.close()
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    let events = try await poll.value
    XCTAssertEqual(events, [])
  }

  func testCloseDuringHandshakePreventsLateConnectionInstall() async throws {
    let subscribeReceived = DispatchSemaphore(value: 0)
    let releaseSubscribe = DispatchSemaphore(value: 0)
    let disconnected = DispatchSemaphore(value: 0)
    let unexpectedRequest = DispatchSemaphore(value: 0)
    let server = try TransportSocketFixture { client in
      let hello = try XCTUnwrap(try readTransportFrame(client))
      try sendTransportFrame(
        .object([
          "id": hello["id"]!,
          "result": .object([
            "apiVersion": .number(1),
            "capabilities": .array([]),
          ]),
        ]), to: client)
      let subscribe = try XCTUnwrap(try readTransportFrame(client))
      XCTAssertEqual(subscribe["method"]?.stringValue, "status.subscribe")
      subscribeReceived.signal()
      XCTAssertEqual(releaseSubscribe.wait(timeout: .now() + 2), .success)
      try sendTransportFrame(
        .object(["id": subscribe["id"]!, "result": idleTransportSnapshot()]), to: client)
      if try readTransportFrame(client) == nil { disconnected.signal() }
      else { unexpectedRequest.signal() }
    }
    defer { server.stop() }
    let transport = SocketTransport(path: server.path, requireRoot: false)

    let connecting = Task { try await transport.connect() }
    let didReceiveSubscribe = await waitForTransportSemaphore(subscribeReceived, timeout: 1)
    XCTAssertTrue(didReceiveSubscribe)
    let started = Date()
    await transport.close()
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    releaseSubscribe.signal()

    do {
      _ = try await connecting.value
      XCTFail("a handshake invalidated by close must not reconnect the transport")
    } catch {}
    let didDisconnect = await waitForTransportSemaphore(disconnected, timeout: 1)
    XCTAssertTrue(didDisconnect)
    XCTAssertEqual(unexpectedRequest.wait(timeout: .now()), .timedOut)
    do {
      _ = try await transport.request(method: "status.get", params: .object([:]))
      XCTFail("closed transport unexpectedly retained a connection")
    } catch {}
  }
}

private final class TransportSocketFixture: @unchecked Sendable {
  private final class HandlerBox: @unchecked Sendable {
    let handler: (FileHandle) throws -> Void
    init(_ handler: @escaping (FileHandle) throws -> Void) { self.handler = handler }
  }

  let directory: URL
  let path: String
  private let stopLock = NSLock()
  private var listener: Int32
  private var stopped = false
  private var worker: Thread?

  init(handler: @escaping (FileHandle) throws -> Void) throws {
    directory = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("dopa-transport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    path = directory.appendingPathComponent("control.sock").path
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var address = try transportSocketAddress(path: path)
    let length = socklen_t(
      MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + path.utf8.count + 1)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(self.listener, $0, length)
      }
    }
    guard bound == 0, Darwin.listen(listener, 4) == 0 else {
      let failure = errno
      Darwin.close(listener)
      throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
    let listener = listener
    let handler = HandlerBox(handler)
    worker = Thread {
      let descriptor = Darwin.accept(listener, nil, nil)
      guard descriptor >= 0 else { return }
      var noSigPipe: Int32 = 1
      _ = withUnsafePointer(to: &noSigPipe) {
        setsockopt(
          descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0,
          socklen_t(MemoryLayout<Int32>.size))
      }
      let client = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      do { try handler.handler(client) } catch {}
    }
    worker?.start()
  }

  deinit { stop() }

  func stop() {
    stopLock.lock()
    guard !stopped else {
      stopLock.unlock()
      return
    }
    stopped = true
    let descriptor = listener
    listener = -1
    stopLock.unlock()
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
    try? FileManager.default.removeItem(at: directory)
  }
}

private func idleTransportSnapshot() -> JSONValue {
  .object([
    "instanceId": .string("daemon-a"),
    "revision": .string("1"),
    "phase": .string("idle"),
    "sessions": .array([]),
    "recoveryPending": .bool(false),
    "confirmed": .object([
      "systemSleepDisabled": .bool(false),
      "keepDisplayOn": .bool(false),
    ]),
  ])
}

private func transportSocketAddress(path: String) throws -> sockaddr_un {
  let bytes = Array(path.utf8)
  var address = sockaddr_un()
  let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw POSIXError(.ENAMETOOLONG)
  }
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

private func readTransportFrame(_ handle: FileHandle) throws -> JSONValue? {
  var data = Data()
  while true {
    let byte = try handle.read(upToCount: 1)
    guard let byte, !byte.isEmpty else { return nil }
    if byte[0] == 0x0A { return try JSONWire.decode(data) }
    data.append(byte[0])
  }
}

private func sendTransportFrame(_ value: JSONValue, to handle: FileHandle) throws {
  try handle.write(contentsOf: JSONWire.encode(value))
}

private func waitForTransportSemaphore(
  _ semaphore: DispatchSemaphore, timeout: TimeInterval
) async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
    }
  }
}
