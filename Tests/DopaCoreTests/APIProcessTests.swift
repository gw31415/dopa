import Darwin
import CDopa
import DopaClient
import DopaProtocol
import Foundation
import XCTest

final class APIProcessTests: XCTestCase {
  /// Reads exact wire ordering rather than DopaConnection's event buffering.
  private final class WirePeer {
    let descriptor: Int32
    var buffer = JSONLineBuffer()
    var pending: [JSONValue] = []

    init(path: String) throws {
      let fd = dopa_unix_socket()
      guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      guard dopa_unix_connect(fd, path) == 0 else {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        Darwin.close(fd)
        throw error
      }
      descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    func send(_ id: String, _ method: String, _ params: JSONValue = .object([:])) throws {
      let data = try JSONWire.encode(.object([
        "id": .string(id), "method": .string(method), "params": params,
      ]))
      let sent = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      guard sent == data.count else {
        throw NSError(domain: "APIProcessTests.WirePeer", code: 1)
      }
    }

    func receive() throws -> JSONValue {
      let deadline = Date().addingTimeInterval(3)
      while pending.isEmpty {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw NSError(domain: "APIProcessTests.WirePeer", code: 2) }
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, Int32(max(1, remaining * 1_000))) > 0 else {
          throw NSError(domain: "APIProcessTests.WirePeer", code: 3)
        }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let received = Darwin.read(descriptor, &bytes, bytes.count)
        guard received > 0 else { throw NSError(domain: "APIProcessTests.WirePeer", code: 4) }
        pending.append(contentsOf: try buffer.append(Data(bytes.prefix(received))))
      }
      return pending.removeFirst()
    }
  }

  private final class Fixture {
    let directory: URL
    let process: Process
    let errorOutput: FileHandle
    var socketPath: String { directory.appendingPathComponent("ipc/control.sock").path }

    init(directory existing: URL? = nil, allowedUID: uid_t? = nil, allowTestAuthorization: Bool = false) throws {
      directory = existing ?? URL(fileURLWithPath: "/tmp/dopa-api-\(UUID().uuidString)")
      if existing == nil {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try "0".write(to: directory.appendingPathComponent("power"), atomically: true, encoding: .utf8)
        try "0".write(to: directory.appendingPathComponent("lid"), atomically: true, encoding: .utf8)
      }
      let errors = directory.appendingPathComponent("daemon-errors")
      FileManager.default.createFile(atPath: errors.path, contents: nil)
      errorOutput = try FileHandle(forWritingTo: errors)
      process = Process()
      process.executableURL = Bundle(for: APIProcessTests.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("DopaTestHarness")
      process.environment = ["DOPA_TEST_DIRECTORY": directory.path, "DOPA_TEST_DAEMON": "1"]
      if let allowedUID { process.environment?["DOPA_TEST_ALLOWED_UID"] = String(allowedUID) }
      if allowTestAuthorization { process.environment?["DOPA_TEST_ADMIN_AUTH"] = "1" }
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errorOutput
      try process.run()
    }

    func connect() throws -> DopaConnection {
      let deadline = Date().addingTimeInterval(5)
      var lastError: Error?
      while process.isRunning && Date() < deadline {
        do { return try DopaConnection(path: socketPath, requireRoot: false) }
        catch { lastError = error }
        usleep(20_000)
      }
      let details = (try? String(contentsOf: directory.appendingPathComponent("daemon-errors"), encoding: .utf8)) ?? ""
      throw NSError(domain: "APIProcessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "daemon connection failed: \(String(describing: lastError)); \(details)"])
    }

    func value(_ name: String) -> String? {
      try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func waitFor(_ name: String, value expected: String) throws {
      let deadline = Date().addingTimeInterval(5)
      while value(name) != expected {
        guard Date() < deadline else {
          throw NSError(domain: "APIProcessTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "timeout waiting for \(name)=\(expected)"])
        }
        usleep(20_000)
      }
    }

    func stop(_ signal: Int32 = SIGTERM) {
      guard process.isRunning else { return }
      _ = kill(process.processIdentifier, signal)
      let deadline = Date().addingTimeInterval(5)
      while process.isRunning && Date() < deadline { usleep(20_000) }
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }

    deinit { stop(); try? errorOutput.close() }
  }

  private func acquire(_ connection: DopaConnection, display: Bool = false, lid: Bool = false) throws -> String {
    let response = try connection.request(method: "session.acquire", params: .object([
      "options": .object(["keepDisplayOn": .bool(display), "stopOnLidClose": .bool(lid)])
    ]))
    return try XCTUnwrap(response["sessionId"]?.stringValue)
  }

  func testObserverDoesNotInhibitAndOwnersAggregateUntilDisconnect() throws {
    let fixture = try Fixture()
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let observer = try fixture.connect()
    defer { observer.close() }
    let initial = try observer.request(method: "status.subscribe")
    XCTAssertEqual(initial["phase"]?.stringValue, "idle")
    XCTAssertEqual(fixture.value("power"), "0")
    let first = try fixture.connect()
    let second = try fixture.connect()
    defer { first.close(); second.close() }
    _ = try acquire(first, display: true)
    let secondID = try acquire(second)
    XCTAssertEqual(fixture.value("power"), "1")
    XCTAssertEqual(fixture.value("display"), "1")
    first.close()
    try fixture.waitFor("display", value: "0")
    XCTAssertEqual(fixture.value("power"), "1")
    _ = try second.request(method: "session.release", params: .object(["sessionId": .string(secondID)]))
    XCTAssertEqual(fixture.value("power"), "0")
    let final = try observer.request(method: "status.get")
    XCTAssertEqual(final["phase"]?.stringValue, "idle")
    XCTAssertEqual(final["sessions"]?.arrayValue?.count, 0)
    XCTAssertTrue(fixture.process.isRunning)
  }

  func testForeignSessionCannotBeReleasedAndUpdateChangesDisplay() throws {
    let fixture = try Fixture()
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = try fixture.connect()
    let stranger = try fixture.connect()
    defer { owner.close(); stranger.close() }
    let id = try acquire(owner)
    XCTAssertThrowsError(try stranger.request(method: "session.release", params: .object(["sessionId": .string(id)])))
    XCTAssertEqual(fixture.value("power"), "1")
    _ = try owner.request(method: "session.update", params: .object([
      "sessionId": .string(id),
      "options": .object(["keepDisplayOn": .bool(true), "stopOnLidClose": .bool(false)])
    ]))
    XCTAssertEqual(fixture.value("display"), "1")
    _ = try owner.request(method: "session.release", params: .object(["sessionId": .string(id)]))
    _ = try owner.request(method: "session.release", params: .object(["sessionId": .string(id)]))
    XCTAssertEqual(fixture.value("power"), "0")
  }

  func testMalformedPeerDoesNotInterruptOtherOwners() throws {
    let fixture = try Fixture()
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = try fixture.connect()
    defer { owner.close() }
    let id = try acquire(owner)
    let raw = dopa_unix_socket()
    XCTAssertGreaterThanOrEqual(raw, 0)
    guard raw >= 0 else { return }
    defer { Darwin.close(raw) }
    XCTAssertEqual(dopa_unix_connect(raw, fixture.socketPath), 0)
    // Duplicate keys must be rejected by framing rather than interpreted
    // differently by the daemon and another implementation.
    let malformed = Data("{\"id\":\"bad\",\"id\":\"other\",\"method\":\"hello\",\"params\":{}}\n".utf8)
    let sent = malformed.withUnsafeBytes { Darwin.write(raw, $0.baseAddress, $0.count) }
    XCTAssertEqual(sent, malformed.count)
    var descriptor = pollfd(fd: raw, events: Int16(POLLIN), revents: 0)
    XCTAssertGreaterThan(poll(&descriptor, 1, 3_000), 0)
    var bytes = [UInt8](repeating: 0, count: 1024)
    let received = Darwin.read(raw, &bytes, bytes.count)
    XCTAssertGreaterThanOrEqual(received, 0)
    if received > 0 {
      let response = try JSONWire.decode(Data(bytes.prefix(received)))
      XCTAssertNotNil(response["error"])
    }
    let status = try owner.request(method: "status.get")
    XCTAssertEqual(status["sessions"]?.arrayValue?.count, 1)
    XCTAssertEqual(fixture.value("power"), "1")
    _ = try owner.request(method: "session.release", params: .object(["sessionId": .string(id)]))
    XCTAssertEqual(fixture.value("power"), "0")
  }

  func testUnconfiguredUIDCannotCompleteHandshake() throws {
    guard geteuid() != 0 else { throw XCTSkip("root is always permitted") }
    let fixture = try Fixture(allowedUID: geteuid() == 501 ? 502 : 501)
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: fixture.socketPath) && Date() < deadline {
      usleep(20_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketPath))
    XCTAssertThrowsError(try DopaConnection(path: fixture.socketPath, requireRoot: false))
    XCTAssertEqual(fixture.value("power"), "0")
    XCTAssertTrue(fixture.process.isRunning)
  }

  func testLidEndsOnlyWatchedSession() throws {
    let fixture = try Fixture()
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let watched = try fixture.connect()
    let other = try fixture.connect()
    defer { watched.close(); other.close() }
    let watchedID = try acquire(watched, lid: true)
    _ = try acquire(other)
    try "1".write(to: fixture.directory.appendingPathComponent("lid"), atomically: true, encoding: .utf8)
    let event = try XCTUnwrap(watched.receive(timeout: 3))
    XCTAssertEqual(event["event"]?.stringValue, "session.ended")
    XCTAssertEqual(event["data"]?["sessionId"]?.stringValue, watchedID)
    XCTAssertEqual(event["data"]?["reason"]?.stringValue, "lid_closed")
    XCTAssertEqual(fixture.value("power"), "1")
    other.close()
    try fixture.waitFor("power", value: "0")
  }

  func testSIGTERMRestoresAndSIGKILLJournalRecoversWithoutReacquisition() throws {
    let fixture = try Fixture()
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = try fixture.connect()
    _ = try acquire(owner)
    fixture.stop(SIGKILL)
    owner.close()
    XCTAssertEqual(fixture.value("power"), "1")
    let restarted = try Fixture(directory: fixture.directory)
    defer { restarted.stop() }
    let client = try restarted.connect()
    defer { client.close() }
    XCTAssertEqual(fixture.value("power"), "0")
    let status = try client.request(method: "status.get")
    XCTAssertEqual(status["sessions"]?.arrayValue?.count, 0)
    _ = try acquire(client, display: true)
    restarted.stop()
    XCTAssertEqual(fixture.value("power"), "0")
    XCTAssertEqual(fixture.value("display"), "0")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("state/session").path))
  }

  func testSameUIDStopAcrossSocketsNotifiesOwnerAndPreservesOtherSession() throws {
    let fixture = try Fixture()
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let manager = try fixture.connect()
    let other = try fixture.connect()
    defer { manager.close(); other.close() }
    let owner = try WirePeer(path: fixture.socketPath)
    try owner.send("hello", "hello", .object([
      "apiVersion": .number(1), "client": .object(["name": .string("owner"), "version": .string("1")]),
    ]))
    let hello = try owner.receive()
    XCTAssertTrue(hello["result"]?["capabilities"]?.arrayValue?.contains(.string("session.stopSessions")) == true)
    try owner.send("acquire", "session.acquire", .object([
      "options": .object(["keepDisplayOn": .bool(true), "stopOnLidClose": .bool(false)]),
    ]))
    let ownerID = try XCTUnwrap(owner.receive()["result"]?["sessionId"]?.stringValue)
    let otherID = try acquire(other)
    let params = JSONValue.object(["sessionIds": .array([.string(ownerID)])])

    let result = try manager.request(method: "session.stopSessions", params: params)

    XCTAssertEqual(result["stoppedSessionIds"], .array([.string(ownerID)]))
    let ended = try owner.receive()
    XCTAssertEqual(ended["event"], .string("session.ended"))
    XCTAssertEqual(ended["data"]?["sessionId"], .string(ownerID))
    XCTAssertEqual(ended["data"]?["reason"], .string("user_stopped"))
    XCTAssertEqual(ended["data"]?["cleanup"], .string("confirmed"))
    XCTAssertEqual(ended["data"]?["revision"], result["revision"])
    let status = try manager.request(method: "status.get")
    XCTAssertEqual(status["sessions"]?.arrayValue?.count, 1)
    XCTAssertEqual(status["sessions"]?.arrayValue?.first?["id"], .string(otherID))
    XCTAssertEqual(fixture.value("power"), "1")
    XCTAssertEqual(fixture.value("display"), "0")
    XCTAssertTrue(fixture.process.isRunning)
    XCTAssertEqual(try manager.request(method: "session.stopSessions", params: params)["stoppedSessionIds"], .array([]))
  }

  func testAdminStopRespondsBeforeOwnerEndAndSnapshotAndLeavesOtherSession() throws {
    let fixture = try Fixture(allowTestAuthorization: true)
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let other = try fixture.connect()
    defer { other.close() }
    let manager = try WirePeer(path: fixture.socketPath)
    try manager.send("hello", "hello", .object([
      "apiVersion": .number(1), "client": .object(["name": .string("test"), "version": .string("1")]),
    ]))
    let hello = try manager.receive()
    XCTAssertTrue(hello["result"]?["capabilities"]?.arrayValue?.contains(.string("admin.stopSessions")) == true)
    try manager.send("subscribe", "status.subscribe")
    let initial = try XCTUnwrap(manager.receive()["result"])
    try manager.send("acquire", "session.acquire", .object([
      "options": .object(["keepDisplayOn": .bool(true), "stopOnLidClose": .bool(false)]),
    ]))
    let managerID = try XCTUnwrap(manager.receive()["result"]?["sessionId"]?.stringValue)
    XCTAssertEqual(try manager.receive()["event"], .string("status.changed"))
    let otherID = try acquire(other)
    XCTAssertEqual(try manager.receive()["event"], .string("status.changed"))
    try manager.send("stop", "admin.stopSessions", .object([
      "sessionIds": .array([.string(managerID)]),
      "authorization": .string(Data(repeating: 0xAB, count: 32).base64EncodedString()),
    ]))
    let message = try manager.receive()
    XCTAssertEqual(message["id"], .string("stop"))
    let response = try XCTUnwrap(message["result"])
    XCTAssertEqual(response["stoppedSessionIds"], .array([.string(managerID)]))
    let ended = try manager.receive()
    XCTAssertEqual(ended["event"], .string("session.ended"))
    XCTAssertEqual(ended["data"]?["sessionId"], .string(managerID))
    XCTAssertEqual(ended["data"]?["reason"], .string("user_stopped"))
    XCTAssertEqual(ended["data"]?["cleanup"], .string("confirmed"))
    XCTAssertEqual(ended["data"]?["revision"], response["revision"])
    let changed = try manager.receive()
    XCTAssertEqual(changed["event"], .string("status.changed"))
    XCTAssertEqual(changed["data"]?["instanceId"], initial["instanceId"])
    let sessions = try XCTUnwrap(changed["data"]?["snapshot"]?["sessions"]?.arrayValue)
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?["id"], .string(otherID))
    XCTAssertEqual(fixture.value("power"), "1")
    XCTAssertEqual(fixture.value("display"), "0")
    XCTAssertTrue(fixture.process.isRunning)
  }

  func testNativeAuthorizationRejectsForgedTokenWithoutMutatingSessions() throws {
    guard geteuid() != 0 else { throw XCTSkip("root does not require an authorization token") }
    let fixture = try Fixture()
    defer { fixture.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = try fixture.connect()
    let manager = try fixture.connect()
    defer { owner.close(); manager.close() }
    let id = try acquire(owner)
    XCTAssertThrowsError(try manager.request(method: "admin.stopSessions", params: .object([
      "sessionIds": .array([.string(id)]),
      "authorization": .string(Data(repeating: 0, count: 32).base64EncodedString()),
    ]))) { error in
      XCTAssertEqual((error as? DopaRemoteError)?.code, "permission_denied")
    }
    let status = try manager.request(method: "status.get")
    XCTAssertEqual(status["sessions"]?.arrayValue?.count, 1)
    XCTAssertEqual(status["sessions"]?.arrayValue?.first?["id"], .string(id))
    XCTAssertEqual(fixture.value("power"), "1")
  }
}
