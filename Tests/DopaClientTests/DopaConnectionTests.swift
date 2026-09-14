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

  func testCloseReleasesConsumedEventsKeepsUnread() throws {
    // Consume some events, then close. Unread events already queued
    // client-side must still arrive in order after close, and repeated close
    // stays safe. The second batch is provably queued before close: the
    // server sends it ahead of the request response, and TCP preserves order,
    // so no in-flight event can be lost to the close.
    let total = 10
    let consumed = 6
    let pad = String(repeating: "x", count: 8_000)
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      for seq in 0..<consumed {
        try sendFrame(
          .object([
            "event": .string("status.changed"),
            "data": .object(["seq": .number(Double(seq)), "pad": .string(pad)]),
          ]), to: client)
      }
      let poke = try XCTUnwrap(try readFrame(client))
      for seq in consumed..<total {
        try sendFrame(
          .object([
            "event": .string("status.changed"),
            "data": .object(["seq": .number(Double(seq)), "pad": .string(pad)]),
          ]), to: client)
      }
      try sendFrame(.object(["id": poke["id"]!, "result": .object([:])]), to: client)
      // Wait for the client to go away instead of sleeping: writing after the
      // peer closed would raise SIGPIPE on this fixture thread and kill the
      // test process. EOF arrives when the client closes.
      do { while try readFrame(client) != nil {} } catch {}
    }
    defer { server.stop() }
    let connection = try DopaConnection(path: server.path, requireRoot: false, clientName: "test")
    for seq in 0..<consumed {
      let event = try XCTUnwrap(try connection.receive(timeout: 2))
      XCTAssertEqual(event["data"]?["seq"], .number(Double(seq)))
    }
    XCTAssertEqual(try connection.request(method: "status.get", timeout: 2), .object([:]))
    connection.close()
    connection.close()
    for seq in consumed..<total {
      let event = try XCTUnwrap(try connection.receive(timeout: 2))
      XCTAssertEqual(event["data"]?["seq"], .number(Double(seq)))
    }
    // Queue drained after close: same as a live receive timeout, nil.
    XCTAssertNil(try connection.receive(timeout: 0.1))
  }

  func testSocketDescriptorSupportsExternalPolling() throws {
    // The accessor exposes the live socket for poll/select so CLI-style
    // loops can wait on the socket and a signal pipe together. -1 after close.
    let eventSent = DispatchSemaphore(value: 0)
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      XCTAssertEqual(eventSent.wait(timeout: .now() + 5), .success)
      try sendFrame(
        .object(["event": .string("status.changed"), "data": .object(["seq": .number(1)])]), to: client)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }
    let connection = try DopaConnection(path: server.path, requireRoot: false, clientName: "test")
    let fd = connection.socketDescriptor
    XCTAssertGreaterThanOrEqual(fd, 0)
    // Nothing readable yet: the hello response was consumed by init.
    var idle = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    XCTAssertEqual(Darwin.poll(&idle, 1, 100), 0)
    XCTAssertEqual(idle.revents, 0)
    eventSent.signal()
    var active = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    XCTAssertGreaterThan(Darwin.poll(&active, 1, 5000), 0)
    XCTAssertNotEqual(active.revents & Int16(POLLIN), 0)
    let event = try XCTUnwrap(try connection.receive(timeout: 2))
    XCTAssertEqual(event["data"]?["seq"], .number(1))
    connection.close()
    XCTAssertEqual(connection.socketDescriptor, -1)
  }

  func testExternalPollCallerCanDrainEventDecodedWithResponse() throws {
    // A server can put a response and its immediately following event
    // in one stream write. request() returns the response and retains the
    // already-decoded event, leaving the kernel socket empty. A caller that
    // combines this descriptor with another poll source must drain receive(0)
    // before entering that external poll.
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]),
        to: client)
      let acquire = try XCTUnwrap(try readFrame(client))
      let sessionID = "ended-immediately"
      var batch = try JSONWire.encode(.object([
        "id": acquire["id"]!,
        "result": .object(["sessionId": .string(sessionID)]),
      ]))
      batch.append(try JSONWire.encode(.object([
        "event": .string("session.ended"),
        "data": .object([
          "sessionId": .string(sessionID),
          "reason": .string("user_stopped"),
          "cleanup": .string("confirmed"),
        ]),
      ])))
      try client.write(contentsOf: batch)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }

    let connection = try DopaConnection(path: server.path, requireRoot: false)
    defer { connection.close() }
    XCTAssertEqual(
      try connection.request(method: "session.acquire")["sessionId"]?.stringValue,
      "ended-immediately")

    var socket = Darwin.pollfd(
      fd: connection.socketDescriptor, events: Int16(POLLIN), revents: 0)
    XCTAssertEqual(
      Darwin.poll(&socket, 1, 100), 0,
      "the event should already be in DopaConnection rather than the kernel socket")
    let event = try XCTUnwrap(try connection.receive(timeout: 0))
    XCTAssertEqual(event["event"]?.stringValue, "session.ended")
    XCTAssertEqual(event["data"]?["sessionId"]?.stringValue, "ended-immediately")
  }

  func testInterruptWakesBlockedReceiveWithoutError() throws {
    // A transport blocked in a long interruptible poll must return
    // promptly (nil, not an error) when a request or close interrupts it.
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }
    let box = ConnectionBox(try DopaConnection(path: server.path, requireRoot: false))
    let probe = ReceiveProbe()
    let done = DispatchSemaphore(value: 0)
    let reader = Thread {
      do { probe.complete(try box.connection.receive(timeout: 30, interruptible: true)) }
      catch { probe.fail(error) }
      done.signal()
    }
    reader.start()
    Thread.sleep(forTimeInterval: 0.3)
    let start = Date()
    box.connection.interruptReceive()
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    XCTAssertNil(try probe.outcome())
    box.connection.close()
  }

  func testCloseWakesLegacyReceivePromptly() throws {
    // Preserve the original one-argument method as a callable function value,
    // and prove that close can wake it even though receive owns the operation
    // lock while blocked in poll.
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }
    let box = ConnectionBox(try DopaConnection(path: server.path, requireRoot: false))
    let probe = ReceiveProbe()
    let entered = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    Thread {
      let legacyReceive: (TimeInterval) throws -> JSONValue? = box.connection.receive(timeout:)
      entered.signal()
      do { probe.complete(try legacyReceive(30)) }
      catch { probe.fail(error) }
      done.signal()
    }.start()
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    Thread.sleep(forTimeInterval: 0.05)

    let start = Date()
    box.connection.close()
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
    XCTAssertNil(try probe.outcome())
  }

  func testInterruptAndCloseRaceIsSafe() throws {
    // Exercise the wake pipe's descriptor lifetime from many interrupting
    // threads while close retires both ends. This used to race a raw tuple,
    // allowing SIGPIPE or a write to a descriptor reused after close.
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }
    let box = ConnectionBox(try DopaConnection(path: server.path, requireRoot: false))
    let readerDone = DispatchSemaphore(value: 0)
    Thread {
      _ = try? box.connection.receive(timeout: 30, interruptible: true)
      readerDone.signal()
    }.start()
    Thread.sleep(forTimeInterval: 0.05)

    let workers = DispatchGroup()
    for _ in 0..<8 {
      workers.enter()
      DispatchQueue.global().async {
        for _ in 0..<500 { box.connection.interruptReceive() }
        workers.leave()
      }
    }
    workers.enter()
    DispatchQueue.global().async {
      box.connection.close()
      workers.leave()
    }
    XCTAssertEqual(workers.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(readerDone.wait(timeout: .now() + 1), .success)
    // Post-close interrupts are also harmless and cannot target a reused FD.
    for _ in 0..<100 { box.connection.interruptReceive() }
  }

  func testInterruptLosesNoEvents() throws {
    // An interrupt that lands before an event only ends the current
    // wait early; the event itself is delivered by the next receive.
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      Thread.sleep(forTimeInterval: 0.5)
      try sendFrame(
        .object(["event": .string("status.changed"), "data": .object(["seq": .number(7)])]),
        to: client)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }
    let box = ConnectionBox(try DopaConnection(path: server.path, requireRoot: false))
    let first = ReceiveProbe()
    let firstDone = DispatchSemaphore(value: 0)
    Thread {
      do { first.complete(try box.connection.receive(timeout: 30, interruptible: true)) }
      catch { first.fail(error) }
      firstDone.signal()
    }.start()
    Thread.sleep(forTimeInterval: 0.1)
    box.connection.interruptReceive()
    XCTAssertEqual(firstDone.wait(timeout: .now() + 5), .success)
    XCTAssertNil(try first.outcome())
    let event = try XCTUnwrap(try box.connection.receive(timeout: 5, interruptible: true))
    XCTAssertEqual(event["data"]?["seq"], .number(7))
    box.connection.close()
  }

  func testStrayInterruptNeverFailsRequests() throws {
    // Request paths are never interruptible, so an interrupt with no
    // waiter (or a stale byte) cannot fail or stall a request.
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      let request = try XCTUnwrap(try readFrame(client))
      try sendFrame(.object(["id": request["id"]!, "result": .object(["ok": .bool(true)])]), to: client)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }
    let connection = try DopaConnection(path: server.path, requireRoot: false)
    connection.interruptReceive()
    connection.interruptReceive()
    XCTAssertEqual(
      try connection.request(method: "status.get", timeout: 5)["ok"]?.boolValue, true)
    connection.close()
  }

  func testEventQueueCapBoundsMemory() throws {
    // The 128-event cap (with the 64KiB frame cap) is the memory bound:
    // 129 in-flight events trip it deterministically and close the stream
    // instead of growing retention.
    let server = try SocketFixture { client in
      let hello = try XCTUnwrap(try readFrame(client))
      try sendFrame(
        .object(["id": hello["id"]!, "result": .object(["apiVersion": .number(1)])]), to: client)
      _ = try XCTUnwrap(try readFrame(client))
      for seq in 0..<130 {
        try sendFrame(
          .object(["event": .string("status.changed"), "data": .object(["seq": .number(Double(seq))])]),
          to: client)
      }
      try sendFrame(.object(["id": .string("1"), "result": .object([:])]), to: client)
      while try readFrame(client) != nil {}
    }
    defer { server.stop() }
    let connection = try DopaConnection(path: server.path, requireRoot: false, clientName: "test")
    XCTAssertThrowsError(try connection.request(method: "status.get", timeout: 5)) { error in
      XCTAssertEqual(error as? DopaClientError, .protocolViolation("event queue is full"))
    }
    XCTAssertThrowsError(try connection.request(method: "status.get", timeout: 2)) {
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

/// Thread-safe box: DopaConnection serializes internally but is not marked
/// Sendable, so tests hand it across threads through this wrapper.
private final class ConnectionBox: @unchecked Sendable {
  let connection: DopaConnection
  init(_ connection: DopaConnection) { self.connection = connection }
}

private final class ReceiveProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var result: JSONValue? = nil
  private var resultSet = false
  private var failure: Error? = nil
  func complete(_ value: JSONValue?) {
    lock.lock()
    result = value
    resultSet = true
    lock.unlock()
  }
  func fail(_ error: Error) {
    lock.lock()
    failure = error
    lock.unlock()
  }
  func outcome() throws -> JSONValue? {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
    return resultSet ? result : nil
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
