import Darwin
import Foundation
import XCTest

@testable import DopaCore

final class ProcessTests: XCTestCase {
  private var binaries: URL {
    Bundle(for: ProcessTests.self).bundleURL.deletingLastPathComponent()
  }
  private func value(_ directory: URL, _ name: String) -> String? {
    try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
  }
  private func write(_ directory: URL, _ name: String, _ text: String) throws {
    try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  private func waitFor(_ directory: URL, _ name: String, _ expected: String, process: Process)
    throws
  {
    let deadline = Date().addingTimeInterval(8)
    while value(directory, name) != expected {
      if !process.isRunning {
        throw DopaError(
          "fixture exited while waiting for \(name): \(value(directory, "stderr") ?? "")")
      }
      guard Date() < deadline else {
        throw DopaError("timeout waiting for \(name): \(value(directory, "stderr") ?? "")")
      }
      usleep(20_000)
    }
  }
  private func waitForExit(_ process: Process) throws {
    let deadline = Date().addingTimeInterval(8)
    while process.isRunning {
      guard Date() < deadline else { throw DopaError("fixture did not exit") }
      usleep(20_000)
    }
    process.waitUntilExit()
  }

  private func fixture(
    _ body: (URL, Process) throws -> Void, display: Bool = true, lid: Bool = false,
    delay: Bool = false, initiallyClosed: Bool = false
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dopa-process-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(directory, "power", "0")
    try write(directory, "lid", initiallyClosed ? "1" : "0")
    if delay { try write(directory, "delay", "1") }
    let errorURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let error = try FileHandle(forWritingTo: errorURL)
    defer { try? error.close() }
    let process = Process()
    process.executableURL = binaries.appendingPathComponent("DopaTestHarness")
    process.environment = [
      "DOPA_TEST_DIRECTORY": directory.path, "DOPA_TEST_DISPLAY": display ? "1" : "0",
      "DOPA_TEST_LID": lid ? "1" : "0",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = error
    try process.run()
    defer {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }
    try body(directory, process)
  }

  func testSignalsAndDeathDuringEnableRestore() throws {
    for (signal, delay) in [
      (SIGINT, false), (SIGTERM, false), (SIGHUP, false), (SIGQUIT, false),
      (SIGTERM, true), (SIGKILL, false), (SIGKILL, true),
    ] {
      try fixture(
        { directory, process in
          try waitFor(directory, delay ? "enabling" : "power", "1", process: process)
          XCTAssertEqual(kill(process.processIdentifier, signal), 0)
          try waitForExit(process)
          let deadline = Date().addingTimeInterval(8)
          while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("state/session").path)
            || value(directory, "display") != "0"
          {
            guard Date() < deadline else {
              throw DopaError("guardian cleanup failed: \(value(directory, "stderr") ?? "")")
            }
            usleep(20_000)
          }
          XCTAssertEqual(value(directory, "power"), "0")
        }, delay: delay)
    }
  }

  func testTerminationWaitsForDetachedGuardianRestoration() throws {
    try fixture { directory, process in
      try waitFor(directory, "display", "1", process: process)
      let identifiers = (value(directory, "guardian-session") ?? "").split(separator: " ")
        .compactMap { Int32($0) }
      XCTAssertEqual(identifiers.count, 2)
      if identifiers.count == 2 {
        XCTAssertGreaterThan(identifiers[0], 0)
        XCTAssertEqual(identifiers[0], identifiers[1])
        XCTAssertNotEqual(identifiers[1], process.processIdentifier)
      }
      try write(directory, "delay-restore", "1")
      XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)
      try waitFor(directory, "restoring", "1", process: process)
      XCTAssertTrue(process.isRunning)
      XCTAssertEqual(value(directory, "power"), "1")
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("state/session").path))
      try waitForExit(process)
      XCTAssertEqual(process.terminationStatus, 0, value(directory, "stderr") ?? "")
      XCTAssertEqual(value(directory, "power"), "0")
      XCTAssertEqual(value(directory, "display"), "0")
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("state/session").path))
    }
  }

  func testLidClosureDefaultsAndReadFailure() throws {
    for (watch, initial, later, display) in [
      (true, false, "1", true), (true, true, "1", true), (true, false, "bad", true),
      (false, false, "1", false),
    ] {
      try fixture(
        { directory, process in
          if !initial {
            try waitFor(directory, "power", "1", process: process)
            if display { try waitFor(directory, "display", "1", process: process) }
            try write(directory, "lid", later)
            if !watch {
              usleep(700_000)
              XCTAssertTrue(process.isRunning)
              XCTAssertEqual(value(directory, "power"), "1")
              XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)
            }
          }
          try waitForExit(process)
          XCTAssertEqual(
            process.terminationStatus, later == "bad" ? 1 : 0, value(directory, "stderr") ?? "")
          XCTAssertEqual(value(directory, "power"), "0")
          XCTAssertFalse(
            FileManager.default.fileExists(
              atPath: directory.appendingPathComponent("state/session").path))
          XCTAssertEqual(value(directory, "display"), !initial && display ? "0" : nil)
        }, display: display, lid: watch, initiallyClosed: initial)
    }
  }

  func testHelpAndInvalidArgumentsNeedNoPrivileges() throws {
    for (arguments, isHelp) in [
      (["--help"], true), (["-h"], true), (["-dlh"], true), (["-ld", "--help"], true),
      (["--invalid"], false), (["-dx"], false),
    ] {
      let process = Process()
      process.executableURL = binaries.appendingPathComponent("dopa")
      process.arguments = arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      try waitForExit(process)
      XCTAssertEqual(process.terminationStatus, isHelp ? 0 : 1)
      if isHelp {
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("--keep-display-on"))
        XCTAssertTrue(text.contains("--stop-on-lid-close"))
        XCTAssertTrue(text.contains("default: off"))
      }
    }
  }
}
