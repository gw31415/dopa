import Darwin
import Foundation
import XCTest

final class CommandTests: XCTestCase {
  private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String, String) {
    let process = Process()
    process.executableURL = Bundle(for: CommandTests.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent(executable)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    // Only bounded help/error output is produced by the commands below.
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
  }

  func testClientHelpAndDaemonHelpDoNotConnectOrRequireRoot() throws {
    let client = try run("dopa", ["-dl", "--help"])
    XCTAssertEqual(client.0, 0)
    XCTAssertTrue(client.1.contains("Usage: dopa"))
    XCTAssertFalse(client.1.contains("Usage: sudo"))
    XCTAssertTrue(client.2.isEmpty)
    let daemon = try run("dopa-daemon", ["--help"])
    XCTAssertEqual(daemon.0, 0)
    XCTAssertTrue(daemon.1.contains("status"))
    XCTAssertTrue(daemon.1.contains("install"))
    XCTAssertTrue(daemon.1.contains("start"))
    XCTAssertTrue(daemon.1.contains("stop"))
    XCTAssertTrue(daemon.1.contains("restart"))
  }

  func testStatusBelongsToDaemonAndInvalidSyntaxUsesExitTwo() throws {
    for (executable, args) in [
      ("dopa", ["status"]), ("dopa", ["--unknown"]),
      ("dopa-daemon", ["status", "--unknown"]),
      ("dopa-daemon", ["install", "--user"]),
      ("dopa-daemon", ["uninstall", "unexpected"]),
      ("dopa-daemon", ["start", "unexpected"]),
      ("dopa-daemon", ["stop", "unexpected"]),
      ("dopa-daemon", ["restart", "unexpected"]),
    ] {
      let result = try run(executable, args)
      XCTAssertEqual(result.0, 2, "\(executable) \(args): \(result.2)")
    }
  }

  func testManagementAndRunRequireRootRatherThanSilentlyShowingHelp() throws {
    guard geteuid() != 0 else { throw XCTSkip("must not invoke privileged commands as root in tests") }
    for command in ["install", "uninstall", "start", "stop", "restart", "run"] {
      let result = try run("dopa-daemon", [command])
      XCTAssertEqual(result.0, 1, command)
      XCTAssertTrue(result.2.contains("root"), "\(command): \(result.2)")
      XCTAssertTrue(result.1.isEmpty, command)
    }
  }
}
