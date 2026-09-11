import XCTest

@testable import DopaCore

final class CoreTests: XCTestCase {
  func testOptionDefaultsAndForwarding() throws {
    XCTAssertEqual(try Options.parse([]), .run(Options()))
    for display in [false, true] {
      for lid in [false, true] {
        let options = Options(keepDisplayOn: display, stopOnLidClose: lid)
        XCTAssertEqual(try Options.parse(options.arguments), .run(options))
      }
    }
    XCTAssertEqual(
      try Options.parse(["-d", "-l"]), .run(Options(keepDisplayOn: true, stopOnLidClose: true)))
    XCTAssertEqual(try Options.parse(["--help"]), .help)
    XCTAssertThrowsError(try Options.parse(["--unknown"]))
  }
}

private final class FakePower: Power {
  var disabled = false
  var failEnable = false
  var failRestore = false
  func readDisabled() throws -> Bool { disabled }
  func setDisabled(_ value: Bool) throws {
    disabled = value
    if value ? failEnable : failRestore { throw DopaError("injected failure after mutation") }
  }
}

extension CoreTests {
  func temporaryDirectory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dopa-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
  }

  func testJournalRecoveryAndOwnership() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state").path
    let power = FakePower()
    do {
      let state = try State(path: path)
      XCTAssertThrowsError(try State(path: path))
      power.disabled = true
      XCTAssertThrowsError(try Session.start(power: power, state: state))
      XCTAssertFalse(try state.pending())
      power.disabled = false
      power.failEnable = true
      XCTAssertThrowsError(try Session.start(power: power, state: state))
      XCTAssertTrue(try state.pending())
      power.failRestore = true
      XCTAssertThrowsError(try Session.recover(power: power, state: state))
      XCTAssertTrue(try state.pending())
    }
    let next = try State(path: path)
    power.failEnable = false
    power.failRestore = false
    try Session.recover(power: power, state: next)
    XCTAssertFalse(power.disabled)
    XCTAssertFalse(try next.pending())
    // The recovery journal has a fixed, versioned format.
    try next.save()
    XCTAssertEqual(
      try String(contentsOfFile: path + "/session", encoding: .utf8), "dopa-v1\noriginal=0\n")
  }

  func testRejectsCorruptAndSymlinkState() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("state")
    let state = try State(path: root.path)
    try state.save()
    let journal = root.appendingPathComponent("session")
    try Data("corrupt".utf8).write(to: journal)
    XCTAssertThrowsError(try state.pending())
    try FileManager.default.removeItem(at: journal)
    try FileManager.default.createSymbolicLink(
      at: journal, withDestinationURL: directory.appendingPathComponent("victim"))
    XCTAssertThrowsError(try state.pending())
    let symlink = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
    XCTAssertThrowsError(try State(path: symlink.path))
  }
}
