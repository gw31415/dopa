import Darwin
import DopaClient
import DopaProtocol
import Foundation
import XCTest

final class DopaConnectionTests: XCTestCase {
  func testHelloRequestEventsAndRemoteErrors() throws {
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      XCTAssertEqual(hello["method"]?.stringValue, "hello")
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object([
          "apiVersion": .number(1),
          "capabilities": .array([.string("admin.stopSessions"), .string("future.operation")]),
          "instanceId": .string("test-instance"),
        ])]), to: client)

      let status = try XCTUnwrap(try readFrame(client))
      XCTAssertEqual(status["method"]?.stringValue, "status.get")
      try sendFrame(
        .object(["event": .string("status.changed"), "data": .object(["revision": .string("2")]), "future": .bool(true)]),
        to: client)
      try sendFrame(
        .object(["id": status["id"]!, "result": .object(["phase": .string("idle")])]), to: client)

      let failure = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object([
          "id": failure["id"]!,
          "error": .object(["code": .string("not_ready"), "message": .string("wait")]),
        ]), to: client)
      let next = try XCTUnwrap(try readFrame(client))
      try sendFrame(.object(["id": next["id"]!, "result": .bool(true)]), to: client)
    }
    defer { server.stop() }

    let connection = try DopaConnection(path: server.path, requireRoot: false, clientName: "test")
    XCTAssertEqual(connection.capabilities, ["admin.stopSessions", "future.operation"])
    XCTAssertEqual(connection.hello["instanceId"]?.stringValue, "test-instance")
    XCTAssertEqual(
      try connection.request(method: "status.get")["phase"]?.stringValue,
      "idle")
    let event = try XCTUnwrap(connection.receive(timeout: 0))
    XCTAssertEqual(event["event"]?.stringValue, "status.changed")
    XCTAssertEqual(event["data"]?["revision"]?.stringValue, "2")
    XCTAssertThrowsError(try connection.request(method: "status.get")) { error in
      XCTAssertEqual((error as? RemoteError)?.code, "not_ready")
      XCTAssertEqual(String(describing: error), "not_ready: wait")
    }
    XCTAssertEqual(try connection.request(method: "status.get").boolValue, true)
    connection.close()
  }

  func testReceiveTimeoutLeavesConnectionUsable() throws {
    let ready = DispatchSemaphore(value: 0)
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      ready.wait()
      try sendFrame(
        .object(["event": .string("status.changed"), "data": .object([:])]), to: client)
    }
    defer {
      ready.signal()
      server.stop()
    }
    let connection = try DopaConnection(path: server.path, requireRoot: false)
    XCTAssertTrue(connection.capabilities.isEmpty)
    XCTAssertNil(try connection.receive(timeout: 0.01))
    ready.signal()
    XCTAssertEqual(try connection.receive(timeout: 2)?["event"]?.stringValue, "status.changed")
  }

  func testRootValidationRejectsUserOwnedSocket() throws {
    let server = try SocketFixture { client in
      try client.close()
    }
    defer { server.stop() }
    XCTAssertThrowsError(try DopaConnection(path: server.path, requireRoot: true)) { error in
      guard case .unsafeSocketPath = error as? DopaClientError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testRequestTimeoutClosesSessionOwningConnection() throws {
    let disconnected = DispatchSemaphore(value: 0)
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      _ = try XCTUnwrap(try readFrame(client))
      // Intentionally omit the response: the timeout must close this socket,
      // which is how the daemon learns to release the client's lease.
      XCTAssertNil(try readFrame(client))
      disconnected.signal()
    }
    defer { server.stop() }
    let connection = try DopaConnection(path: server.path, requireRoot: false)
    defer { connection.close() }
    XCTAssertThrowsError(try connection.request(method: "session.acquire", timeout: 0.05)) {
      guard case .timedOut = $0 as? DopaClientError else { return XCTFail("unexpected error: \($0)") }
    }
    XCTAssertEqual(disconnected.wait(timeout: .now() + 2), .success)
    XCTAssertThrowsError(try connection.request(method: "status.get")) {
      XCTAssertEqual($0 as? DopaClientError, .connectionClosed)
    }
  }

  func testMalformedEventClosesConnection() throws {
    let disconnected = DispatchSemaphore(value: 0)
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      try sendFrame(.object(["event": .string("status.changed"), "id": .string("bad"), "data": .object([:])]), to: client)
      XCTAssertNil(try readFrame(client))
      disconnected.signal()
    }
    defer { server.stop() }
    let connection = try DopaConnection(path: server.path, requireRoot: false)
    defer { connection.close() }
    XCTAssertThrowsError(try connection.receive(timeout: 2))
    XCTAssertEqual(disconnected.wait(timeout: .now() + 2), .success)
  }
}

private final class SocketFixture {
  private final class HandlerBox: @unchecked Sendable {
    let handler: (FileHandle) throws -> Void
    init(_ handler: @escaping (FileHandle) throws -> Void) { self.handler = handler }
  }

  let directory: URL
  let path: String
  private var listener: Int32
  private let stopLock = NSLock()
  private var stopped = false
  private var worker: Thread?

  init(handler: @escaping (FileHandle) throws -> Void) throws {
    directory = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("dopa-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    path = directory.appendingPathComponent("control.sock").path
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var address = try makeAddress(path: path)
    let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + path.utf8.count + 1)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(self.listener, $0, length)
      }
    }
    guard bound == 0, Darwin.listen(self.listener, 4) == 0 else {
      let failure = errno
      Darwin.close(self.listener)
      throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
    let listenerFD = self.listener
    let handler = HandlerBox(handler)
    worker = Thread {
      let client = Darwin.accept(listenerFD, nil, nil)
      guard client >= 0 else { return }
      let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
      do { try handler.handler(handle) } catch { }
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

private func makeAddress(path: String) throws -> sockaddr_un {
  let bytes = Array(path.utf8)
  var address = sockaddr_un()
  let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw DopaClientError.invalidSocketPath
  }
  address.sun_len = UInt8(offset + bytes.count + 1)
  address.sun_family = sa_family_t(AF_UNIX)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { pathPointer in
      for (index, byte) in bytes.enumerated() { pathPointer[index] = CChar(bitPattern: byte) }
      pathPointer[bytes.count] = 0
    }
  }
  return address
}

private func readFrame(_ handle: FileHandle) throws -> JSONValue? {
  var data = Data()
  while true {
    let byte = try handle.read(upToCount: 1)
    guard let byte, !byte.isEmpty else { return nil }
    if byte[0] == 0x0A { return try JSONWire.decode(data) }
    data.append(byte[0])
  }
}

private func sendFrame(_ value: JSONValue, to handle: FileHandle) throws {
  try handle.write(contentsOf: JSONWire.encode(value))
}
