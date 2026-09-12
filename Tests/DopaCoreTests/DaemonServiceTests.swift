import Darwin
import DopaProtocol
import Foundation
import XCTest

@testable import DopaCore

final class DaemonServiceTests: XCTestCase {
  final class FakePower: Power {
    var disabled = false
    var failRestore = false
    func readDisabled() throws -> Bool { disabled }
    func setDisabled(_ value: Bool) throws {
      if !value && failRestore { throw DopaError("restore failure") }
      disabled = value
    }
  }
  final class FakeControls: Controls {
    var display = false
    var lid = false
    var failRelease = false
    func keepDisplayOn() throws { display = true }
    func releaseDisplay() throws {
      if failRelease { throw DopaError("display release failure") }
      display = false
    }
    func lidClosed() throws -> Bool { lid }
  }
  func withEngine(_ test: (DaemonEngine, FakePower, FakeControls) throws -> Void) throws {
    let path = NSTemporaryDirectory() + "dopa-engine-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    let state = try State(path: path)
    let power = FakePower()
    let controls = FakeControls()
    let engine = DaemonEngine(state: state, power: power, controls: controls)
    try test(engine, power, controls)
  }
  func peer(_ uid: uid_t = 501) -> ServicePeer {
    let peer = ServicePeer(
      fd: Descriptor(Darwin.open("/dev/null", O_RDONLY)), uid: uid, pid: getpid())
    peer.hello = true
    peer.name = "test"
    return peer
  }
  func call(
    _ engine: DaemonEngine, _ peer: ServicePeer, _ method: String,
    _ params: JSONValue = .object([:])
  ) -> JSONValue {
    engine.handle(
      .object(["id": .string(UUID().uuidString), "method": .string(method), "params": params]),
      peer: peer)
  }
  func acquire(
    _ engine: DaemonEngine, _ peer: ServicePeer, display: Bool = false, lid: Bool = false
  ) -> JSONValue {
    call(
      engine, peer, "session.acquire",
      .object(["options": .object(["keepDisplayOn": .bool(display), "stopOnLidClose": .bool(lid)])])
    )
  }
  func testOwnershipAggregationAndObserver() throws {
    try withEngine { engine, power, controls in
      let one = peer()
      let two = peer()
      let observer = peer()
      XCTAssertTrue(
        call(engine, observer, "status.subscribe")["result"]?["phase"] == .string("idle"))
      XCTAssertTrue(!power.disabled)
      let id = acquire(engine, one, display: true)["result"]!["sessionId"]!
      XCTAssertTrue(acquire(engine, two)["error"] == nil)
      XCTAssertTrue(power.disabled && controls.display)
      XCTAssertTrue(
        call(engine, two, "session.release", .object(["sessionId": id]))["error"]?["code"]
          == .string("session_not_owned"))
      engine.disconnect(one.fd.value)
      XCTAssertTrue(power.disabled && !controls.display)
      engine.disconnect(two.fd.value)
      XCTAssertTrue(!power.disabled)
      XCTAssertTrue(try !engine.state.pending())
    }
  }
  func testFailedRestorePreservesJournalAndRejectsAcquire() throws {
    try withEngine { engine, power, _ in
      let one = peer()
      let two = peer()
      _ = acquire(engine, one)
      power.failRestore = true
      engine.disconnect(one.fd.value)
      XCTAssertTrue(engine.phase == "degraded")
      XCTAssertTrue(try engine.state.pending())
      XCTAssertTrue(acquire(engine, two)["error"]?["code"] == .string("not_ready"))
      power.failRestore = false
      try engine.prepareShutdown()
      XCTAssertTrue(engine.phase == "draining")
      XCTAssertTrue(try !engine.state.pending())
    }
  }
  func testFailedDisplayCleanupRetainsJournalAndRestoresSystem() throws {
    try withEngine { engine, power, controls in
      let one = peer()
      _ = acquire(engine, one, display: true)
      controls.failRelease = true
      engine.disconnect(one.fd.value)
      XCTAssertTrue(!power.disabled)
      XCTAssertTrue(try engine.state.pending())
      XCTAssertTrue(engine.phase == "degraded")
    }
  }
  func testLidEndsOnlyOptedInSessionAndShutdownDrains() throws {
    try withEngine { engine, power, controls in
      let one = peer()
      let two = peer()
      _ = acquire(engine, one, lid: true)
      _ = acquire(engine, two)
      controls.lid = true
      engine.checkLid()
      XCTAssertTrue(engine.sessions.count == 1)
      XCTAssertTrue(power.disabled)
      XCTAssertTrue(engine.takeEvents().first?.1["data"]?["reason"] == .string("lid_closed"))
      XCTAssertTrue(
        call(engine, two, "admin.prepareShutdown")["error"]?["code"] == .string("permission_denied")
      )
      try engine.prepareShutdown()
      XCTAssertTrue(!power.disabled)
      XCTAssertTrue(acquire(engine, one)["error"]?["code"] == .string("shutting_down"))
    }
  }
  func testConflictAndClosedLidDoNotMutate() throws {
    try withEngine { engine, power, controls in
      let one = peer()
      controls.lid = true
      XCTAssertTrue(acquire(engine, one, lid: true)["error"]?["code"] == .string("lid_closed"))
      power.disabled = true
      XCTAssertTrue(acquire(engine, one)["error"]?["code"] == .string("power_conflict"))
      XCTAssertTrue(engine.sessions.isEmpty)
      XCTAssertTrue(try !engine.state.pending())
      XCTAssertTrue(power.disabled)
    }
  }
  func testUpdateCannotAcquireWithInvalidSessionID() throws {
    try withEngine { engine, power, _ in
      let one = peer()
      let response = call(
        engine, one, "session.update",
        .object([
          "sessionId": .null,
          "options": .object(["keepDisplayOn": .bool(false), "stopOnLidClose": .bool(false)]),
        ]))
      XCTAssertEqual(response["error"]?["code"], .string("invalid_params"))
      XCTAssertTrue(engine.sessions.isEmpty)
      XCTAssertFalse(power.disabled)
    }
  }

  func testSlowPeerQueueIsBounded() {
    let slow = peer()
    let healthy = peer()
    let frame = JSONValue.object([
      "event": .string("test"), "data": .string(String(repeating: "x", count: 60_000)),
    ])
    for _ in 0..<5 { slow.enqueue(frame) }
    XCTAssertTrue(slow.dead)
    XCTAssertLessThanOrEqual(slow.output.count, 262_144)
    healthy.enqueue(.object(["id": .string("1"), "result": .object([:])]))
    XCTAssertFalse(healthy.dead)
    XCTAssertFalse(healthy.output.isEmpty)
  }

  func testFailedReleaseIsNotLaterAcknowledgedAsSuccess() throws {
    try withEngine { engine, power, _ in
      let one = peer()
      let id = acquire(engine, one)["result"]!["sessionId"]!
      power.failRestore = true
      let params = JSONValue.object(["sessionId": id])
      XCTAssertEqual(
        call(engine, one, "session.release", params)["error"]?["code"], .string("recovery_failed"))
      XCTAssertEqual(
        call(engine, one, "session.release", params)["error"]?["code"], .string("recovery_failed"))
      XCTAssertTrue(try engine.state.pending())
    }
  }

  func testHelloVersionAndUnknownParameter() throws {
    try withEngine { engine, power, _ in
      let one = peer()
      one.hello = false
      XCTAssertEqual(call(engine, one, "status.get")["error"]?["code"], .string("not_ready"))
      let unsupported = call(
        engine, one, "hello",
        .object([
          "apiVersion": .number(2),
          "client": .object(["name": .string("test"), "version": .string("1")]),
        ]))
      XCTAssertEqual(unsupported["error"]?["code"], .string("unsupported_version"))
      XCTAssertEqual(unsupported["error"]?["details"]?["supportedVersions"], .array([.number(1)]))
      XCTAssertTrue(one.closing)
      let two = peer()
      XCTAssertEqual(
        call(
          engine, two, "session.acquire",
          .object([
            "options": .object([
              "keepDisplayOn": .bool(false), "stopOnLidClose": .bool(false), "typo": .bool(true),
            ])
          ]))["error"]?["code"], .string("invalid_params"))
      XCTAssertFalse(power.disabled)
    }
  }
}
