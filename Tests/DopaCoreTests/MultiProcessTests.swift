import Darwin
import Foundation
import XCTest

@testable import DopaCore

final class MultiProcessTests: XCTestCase {
  private struct Client {
    let process: Process
    let stderr: URL
  }

  private var binaries: URL {
    Bundle(for: MultiProcessTests.self).bundleURL.deletingLastPathComponent()
  }

  private func value(_ directory: URL, _ name: String) -> String? {
    try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
  }

  private func write(_ directory: URL, _ name: String, _ text: String) throws {
    try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private func makeDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(
      "dopa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try write(directory, "power", "0")
    try write(directory, "lid", "0")
    return directory
  }

  private func spawn(
    _ directory: URL, name: String, display: Bool = false, lid: Bool = false
  ) throws -> Client {
    let stderr = directory.appendingPathComponent("stderr-\(name)")
    FileManager.default.createFile(atPath: stderr.path, contents: nil)
    let process = Process()
    process.executableURL = binaries.appendingPathComponent("DopaTestHarness")
    process.environment = [
      "DOPA_TEST_DIRECTORY": directory.path,
      "DOPA_TEST_DISPLAY": display ? "1" : "0",
      "DOPA_TEST_LID": lid ? "1" : "0",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = try FileHandle(forWritingTo: stderr)
    try process.run()
    return Client(process: process, stderr: stderr)
  }

  private func cleanup(_ clients: [Client], directory: URL) {
    for client in clients where client.process.isRunning {
      kill(client.process.processIdentifier, SIGKILL)
      client.process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: directory)
  }

  private func diagnostic(_ client: Client) -> String {
    value(client.stderr.deletingLastPathComponent(), client.stderr.lastPathComponent) ?? ""
  }

  private func waitFor(
    _ directory: URL, _ name: String, _ expected: String, clients: [Client]
  ) throws {
    let deadline = Date().addingTimeInterval(8)
    while value(directory, name) != expected {
      if clients.allSatisfy({ !$0.process.isRunning }) {
        throw DopaError(
          "all fixtures exited while waiting for " + name + ": "
            + clients.map(diagnostic).joined(separator: " | "))
      }
      guard Date() < deadline else {
        throw DopaError(
          "timeout waiting for " + name + ": " + (value(directory, "stderr") ?? ""))
      }
      usleep(20_000)
    }
  }

  private func waitForText(_ client: Client, _ text: String) throws {
    let deadline = Date().addingTimeInterval(8)
    while !(value(client.stderr.deletingLastPathComponent(), client.stderr.lastPathComponent)
      ?? "").contains(text)
    {
      if !client.process.isRunning {
        throw DopaError("fixture exited before " + text + ": " + diagnostic(client))
      }
      guard Date() < deadline else {
        throw DopaError("timeout waiting for " + text + ": " + diagnostic(client))
      }
      usleep(20_000)
    }
  }

  private func waitForExit(_ client: Client) throws {
    let deadline = Date().addingTimeInterval(8)
    while client.process.isRunning {
      guard Date() < deadline else {
        throw DopaError("fixture did not exit: " + diagnostic(client))
      }
      usleep(20_000)
    }
    client.process.waitUntilExit()
  }

  private func terminate(_ client: Client, with signal: Int32) throws {
    if client.process.isRunning {
      XCTAssertEqual(kill(client.process.processIdentifier, signal), 0)
    }
    try waitForExit(client)
  }

  private func guardianPID(_ directory: URL) -> Int32? {
    guard let marker = value(directory, "guardian-session") else { return nil }
    return marker.split { $0 == " " || $0 == "\n" }.compactMap { Int32($0) }.last
  }

  private func waitForGuardianChange(
    _ directory: URL, from oldPID: Int32, clients: [Client]
  ) throws -> Int32 {
    let deadline = Date().addingTimeInterval(8)
    while true {
      if let pid = guardianPID(directory), pid != oldPID { return pid }
      if clients.allSatisfy({ !$0.process.isRunning }) {
        throw DopaError("all fixtures exited while waiting for coordinator recovery")
      }
      guard Date() < deadline else { throw DopaError("timeout waiting for coordinator recovery") }
      usleep(20_000)
    }
  }

  private func enableMarkers(_ directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter {
      $0.hasPrefix("enable-")
    } ?? []
  }

  private func restoreMarkers(_ directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter {
      $0.hasPrefix("restore-")
    } ?? []
  }

  func testConcurrentClientsRestoreOnlyAfterLastExit() throws {
    let directory = try makeDirectory()
    var clients: [Client] = []
    defer { cleanup(clients, directory: directory) }
    let first = try spawn(directory, name: "first")
    clients.append(first)
    let second = try spawn(directory, name: "second")
    clients.append(second)
    try waitFor(directory, "power", "1", clients: clients)
    try waitForText(first, "sleep disabled;")
    try waitForText(second, "sleep disabled;")

    try terminate(first, with: SIGTERM)
    XCTAssertTrue(second.process.isRunning)
    XCTAssertEqual(value(directory, "power"), "1")
    try terminate(second, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "0")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("state/session").path)
    )
  }

  func testKilledNonLastClientKeepsSleepDisabled() throws {
    let directory = try makeDirectory()
    var clients: [Client] = []
    defer { cleanup(clients, directory: directory) }
    let first = try spawn(directory, name: "first")
    clients.append(first)
    let second = try spawn(directory, name: "second")
    clients.append(second)
    try waitFor(directory, "power", "1", clients: clients)
    try waitForText(first, "sleep disabled;")
    try waitForText(second, "sleep disabled;")

    try terminate(first, with: SIGKILL)
    XCTAssertTrue(second.process.isRunning)
    XCTAssertEqual(value(directory, "power"), "1")
    try terminate(second, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "0")
  }

  func testDisplayAndLidOptionsArePerClient() throws {
    let directory = try makeDirectory()
    var clients: [Client] = []
    defer { cleanup(clients, directory: directory) }
    let display = try spawn(directory, name: "display", display: true)
    clients.append(display)
    let follower = try spawn(directory, name: "follower")
    clients.append(follower)
    try waitFor(directory, "power", "1", clients: clients)
    try waitFor(directory, "display", "1", clients: clients)
    try waitForText(display, "sleep disabled;")
    try waitForText(follower, "sleep disabled;")

    try terminate(display, with: SIGTERM)
    XCTAssertTrue(follower.process.isRunning)
    XCTAssertEqual(value(directory, "display"), "0")
    XCTAssertEqual(value(directory, "power"), "1")
    try terminate(follower, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "0")

    let watched = try spawn(directory, name: "watched", lid: true)
    clients.append(watched)
    let unwatched = try spawn(directory, name: "unwatched")
    clients.append(unwatched)
    try waitFor(directory, "power", "1", clients: clients)
    try waitForText(watched, "sleep disabled;")
    try waitForText(unwatched, "sleep disabled;")
    try write(directory, "lid", "1")
    try waitForExit(watched)
    XCTAssertTrue(unwatched.process.isRunning)
    XCTAssertEqual(value(directory, "power"), "1")
    try terminate(unwatched, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "0")
  }

  func testSimultaneousStartupUsesOneCoordinator() throws {
    let directory = try makeDirectory()
    var clients: [Client] = []
    defer { cleanup(clients, directory: directory) }
    for name in ["one", "two", "three"] {
      clients.append(try spawn(directory, name: name))
    }
    try waitFor(directory, "power", "1", clients: clients)
    for client in clients { try waitForText(client, "sleep disabled;") }
    XCTAssertEqual(enableMarkers(directory).count, 1)
    for client in clients.dropLast() { try terminate(client, with: SIGTERM) }
    XCTAssertEqual(value(directory, "power"), "1")
    try terminate(clients.last!, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "0")
  }

  func testCoordinatorRecoveryAfterKillReelectsAndRecoversJournal() throws {
    let directory = try makeDirectory()
    var clients: [Client] = []
    defer { cleanup(clients, directory: directory) }
    let first = try spawn(directory, name: "first")
    clients.append(first)
    let second = try spawn(directory, name: "second")
    clients.append(second)
    try waitFor(directory, "power", "1", clients: clients)
    try waitForText(first, "sleep disabled;")
    try waitForText(second, "sleep disabled;")
    guard let oldGuardian = guardianPID(directory) else {
      throw DopaError("guardian marker was not written")
    }
    XCTAssertNotEqual(oldGuardian, first.process.processIdentifier)
    XCTAssertNotEqual(oldGuardian, second.process.processIdentifier)
    XCTAssertEqual(kill(oldGuardian, SIGKILL), 0)

    let newGuardian = try waitForGuardianChange(directory, from: oldGuardian, clients: clients)
    XCTAssertNotEqual(oldGuardian, newGuardian)
    try waitFor(directory, "power", "1", clients: clients)
    XCTAssertTrue(first.process.isRunning)
    XCTAssertTrue(second.process.isRunning)

    try terminate(first, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "1")
    try terminate(second, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "0")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("state/session").path)
    )
  }

  func testFreshFrontendRecoversAfterKilledCoordinatorAndStaleSocket() throws {
    let directory = try makeDirectory()
    var clients: [Client] = []
    defer { cleanup(clients, directory: directory) }
    let first = try spawn(directory, name: "old")
    clients.append(first)
    try waitFor(directory, "power", "1", clients: clients)
    try waitForText(first, "sleep disabled;")
    guard let oldGuardian = guardianPID(directory) else {
      throw DopaError("guardian marker was not written")
    }
    XCTAssertNotEqual(oldGuardian, first.process.processIdentifier)

    // Freeze the old client so it cannot reconnect while the coordinator is
    // being killed. This leaves both the socket pathname and journal behind.
    XCTAssertEqual(kill(first.process.processIdentifier, SIGSTOP), 0)
    XCTAssertEqual(kill(oldGuardian, SIGKILL), 0)
    XCTAssertEqual(kill(first.process.processIdentifier, SIGKILL), 0)
    first.process.waitUntilExit()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("state/session").path)
    )

    let fresh = try spawn(directory, name: "fresh")
    clients.append(fresh)
    try waitFor(directory, "power", "1", clients: clients)
    try waitForText(fresh, "sleep disabled;")
    XCTAssertFalse(restoreMarkers(directory).isEmpty)
    try terminate(fresh, with: SIGTERM)
    XCTAssertEqual(value(directory, "power"), "0")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("state/session").path)
    )
  }
}
