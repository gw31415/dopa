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
  func withEngine(
    authorizationVerifier: @escaping (Data) -> Bool = { _ in false },
    _ test: (DaemonEngine, FakePower, FakeControls) throws -> Void
  ) throws {
    let path = NSTemporaryDirectory() + "dopa-engine-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    let state = try State(path: path)
    let power = FakePower()
    let controls = FakeControls()
    let engine = DaemonEngine(
      state: state, power: power, controls: controls, authorizationVerifier: authorizationVerifier)
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

  private var authorizationData: Data { Data(repeating: 0xAB, count: 32) }

  private func stopParams(_ ids: [JSONValue], authorization: JSONValue = .null) -> JSONValue {
    .object(["sessionIds": .array(ids), "authorization": authorization])
  }

  private func userStopParams(_ ids: [JSONValue]) -> JSONValue {
    .object(["sessionIds": .array(ids)])
  }

  func testSameUIDStopAcrossConnectionsPreservesDisplayAggregateAndNotifiesOwners() throws {
    for uid in [uid_t(501), uid_t(0)] {
      var checks = 0
      try withEngine(authorizationVerifier: { _ in checks += 1; return false }) { engine, power, controls in
        let owner = peer(uid)
        let otherDisplayOwner = peer(uid)
        let otherUser = peer(uid == 0 ? 501 : 0)
        let manager = peer(uid)
        let targetID = acquire(engine, owner, display: true)["result"]!["sessionId"]!
        let displayID = acquire(engine, otherDisplayOwner, display: true)["result"]!["sessionId"]!
        let survivorID = acquire(engine, otherUser)["result"]!["sessionId"]!
        let result = call(engine, manager, "session.stopSessions", userStopParams([targetID, .string("already-ended")]))
        XCTAssertNil(result["error"])
        XCTAssertEqual(result["result"]?["stoppedSessionIds"], .array([targetID]))
        XCTAssertTrue(power.disabled && controls.display)
        XCTAssertEqual(engine.sessions.count, 2)
        let events = engine.takeEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, owner.fd.value)
        XCTAssertEqual(events.first?.1["data"]?["reason"], .string("user_stopped"))
        XCTAssertEqual(events.first?.1["data"]?["cleanup"], .string("confirmed"))
        XCTAssertEqual(events.first?.1["data"]?["revision"], result["result"]?["revision"])

        XCTAssertNil(call(engine, manager, "session.stopSessions", userStopParams([displayID]))["error"])
        XCTAssertTrue(power.disabled)
        XCTAssertFalse(controls.display)
        XCTAssertEqual(engine.sessions.count, 1)
        XCTAssertEqual(engine.sessions[otherUser.fd.value]?.id, survivorID.stringValue)
        XCTAssertEqual(engine.takeEvents().first?.0, otherDisplayOwner.fd.value)
        XCTAssertEqual(engine.phase, "active")
        XCTAssertFalse(engine.draining)
        XCTAssertEqual(checks, 0)

        let replacementID = acquire(engine, owner)["result"]!["sessionId"]!
        XCTAssertNotEqual(replacementID, targetID)
        let before = engine.snapshot()
        let repeated = call(engine, manager, "session.stopSessions", userStopParams([targetID, displayID]))
        XCTAssertNil(repeated["error"])
        XCTAssertEqual(repeated["result"]?["stoppedSessionIds"], .array([]))
        XCTAssertEqual(engine.snapshot(), before)
        XCTAssertTrue(engine.takeEvents().isEmpty)
      }
    }
  }

  func testSameUIDStopRejectsMixedUIDSelectionAtomicallyIncludingForRoot() throws {
    try withEngine { engine, power, controls in
      let userOwner = peer(501)
      let rootOwner = peer(0)
      let userID = acquire(engine, userOwner, display: true)["result"]!["sessionId"]!
      let rootID = acquire(engine, rootOwner)["result"]!["sessionId"]!
      let before = engine.snapshot()
      for uid in [uid_t(501), uid_t(0)] {
        let manager = peer(uid)
        for ids in [[userID, rootID], [rootID, userID]] {
          let response = call(engine, manager, "session.stopSessions", userStopParams(ids))
          XCTAssertEqual(response["error"]?["code"], .string("permission_denied"))
          XCTAssertEqual(engine.snapshot(), before)
          XCTAssertTrue(engine.takeEvents().isEmpty)
          XCTAssertTrue(power.disabled && controls.display)
        }
      }
    }
  }

  func testSameUIDStopValidatesIDsAndRejectsCallerSuppliedIdentityOrAuthorization() throws {
    try withEngine { engine, power, _ in
      let owner = peer()
      let manager = peer()
      let id = acquire(engine, owner)["result"]!["sessionId"]!
      let before = engine.snapshot()
      let invalid: [JSONValue] = [
        .object([:]), .object(["sessionIds": .string("not-an-array")]),
        .object(["sessionIds": .array([id]), "peerUID": .number(501)]),
        stopParams([id]), userStopParams([]), userStopParams([id, id]),
        userStopParams([id, .null]), userStopParams([.string("")]),
        userStopParams([.string("bad\nID")]),
        userStopParams([.string(String(repeating: "x", count: 129))]),
        userStopParams((0..<33).map { .string(String($0)) }),
      ]
      for params in invalid {
        let response = call(engine, manager, "session.stopSessions", params)
        XCTAssertEqual(response["error"]?["code"], .string("invalid_params"))
        XCTAssertEqual(engine.snapshot(), before)
      }
      XCTAssertTrue(power.disabled)
      XCTAssertTrue(engine.takeEvents().isEmpty)
    }
  }

  func testSameUIDStopCleanupFailureKeepsUnselectedSessionsAndCannotSucceedOnRetry() throws {
    for leaveSurvivor in [false, true] {
      try withEngine { engine, power, controls in
        let owner = peer()
        let manager = peer()
        let survivor = peer(0)
        let id = acquire(engine, owner, display: true)["result"]!["sessionId"]!
        let survivorID = leaveSurvivor ? acquire(engine, survivor)["result"]!["sessionId"] : nil
        if leaveSurvivor { controls.failRelease = true } else { power.failRestore = true }
        let params = userStopParams([id])
        XCTAssertEqual(call(engine, manager, "session.stopSessions", params)["error"]?["code"], .string("recovery_failed"))
        XCTAssertEqual(engine.phase, "degraded")
        XCTAssertEqual(engine.sessions.count, leaveSurvivor ? 1 : 0)
        XCTAssertEqual(engine.sessions[survivor.fd.value]?.id, survivorID?.stringValue)
        XCTAssertNil(engine.disabled)
        XCTAssertNil(engine.display)
        XCTAssertTrue(try engine.state.pending())
        let events = engine.takeEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.1["data"]?["reason"], .string("user_stopped"))
        XCTAssertEqual(events.first?.1["data"]?["cleanup"], .string("failed"))
        XCTAssertEqual(call(engine, manager, "session.stopSessions", params)["error"]?["code"], .string("recovery_failed"))
        XCTAssertEqual(acquire(engine, owner)["error"]?["code"], .string("not_ready"))
      }
    }
  }

  func testAdminStopRequiresAuthorizationBeforeChangingAnySession() throws {
    var checks = 0
    try withEngine(authorizationVerifier: { _ in checks += 1; return false }) { engine, power, _ in
      let owner = peer()
      let manager = peer()
      let id = acquire(engine, owner)["result"]!["sessionId"]!
      let before = engine.snapshot()
      XCTAssertEqual(
        call(engine, manager, "admin.stopSessions", stopParams([id]))["error"]?["code"],
        .string("permission_denied"))
      let token = authorizationData.base64EncodedString()
      let denied = call(
        engine, manager, "admin.stopSessions", stopParams([id], authorization: .string(token)))
      XCTAssertEqual(denied["error"]?["code"], .string("permission_denied"))
      XCTAssertFalse(String(describing: denied).contains(token))
      XCTAssertEqual(checks, 1)
      XCTAssertEqual(engine.snapshot(), before)
      XCTAssertTrue(power.disabled)
      XCTAssertTrue(engine.takeEvents().isEmpty)
    }
  }

  func testAdminStopValidatesEveryFieldEvenForRoot() throws {
    try withEngine { engine, power, _ in
      let owner = peer()
      let manager = peer(0)
      let id = acquire(engine, owner)["result"]!["sessionId"]!
      let before = engine.snapshot()
      let invalid: [JSONValue] = [
        .object(["sessionIds": .array([id])]),
        .object(["sessionIds": .array([id]), "authorization": .null, "unknown": .bool(true)]),
        stopParams([]), stopParams([id, id]), stopParams([.null]), stopParams([.string("")]),
        stopParams([.string("bad\nID")]), stopParams([.string(String(repeating: "x", count: 129))]),
        stopParams((0..<33).map { .string(String($0)) }),
        stopParams([id], authorization: .bool(true)),
        stopParams([id], authorization: .string("bad-token")),
      ]
      for params in invalid {
        let response = call(engine, manager, "admin.stopSessions", params)
        XCTAssertEqual(response["error"]?["code"], .string("invalid_params"))
        XCTAssertEqual(engine.snapshot(), before)
      }
      XCTAssertTrue(power.disabled)
      XCTAssertTrue(engine.takeEvents().isEmpty)
    }
  }

  func testAuthorizedStopSelectsOnlyConfirmedIDsAndNotifiesOwner() throws {
    var checkedData: Data?
    try withEngine(authorizationVerifier: { checkedData = $0; return true }) { engine, power, controls in
      let owner = peer(0)
      let survivor = peer()
      let manager = peer()
      let targetID = acquire(engine, owner, display: true)["result"]!["sessionId"]!
      let survivorID = acquire(engine, survivor)["result"]!["sessionId"]!
      let result = call(
        engine, manager, "admin.stopSessions",
        stopParams([targetID, .string("already-ended")],
          authorization: .string(authorizationData.base64EncodedString())))
      XCTAssertEqual(checkedData, authorizationData)
      XCTAssertNil(result["error"])
      XCTAssertEqual(result["result"]?["stoppedSessionIds"], .array([targetID]))
      XCTAssertEqual(engine.sessions.count, 1)
      XCTAssertEqual(engine.sessions[survivor.fd.value]?.id, survivorID.stringValue)
      XCTAssertTrue(power.disabled)
      XCTAssertFalse(controls.display)
      XCTAssertFalse(engine.draining)
      let events = engine.takeEvents()
      XCTAssertEqual(events.count, 1)
      XCTAssertEqual(events.first?.0, owner.fd.value)
      XCTAssertEqual(events.first?.1["event"], .string("session.ended"))
      XCTAssertEqual(events.first?.1["data"]?["sessionId"], targetID)
      XCTAssertEqual(events.first?.1["data"]?["reason"], .string("user_stopped"))
      XCTAssertEqual(events.first?.1["data"]?["cleanup"], .string("confirmed"))
      XCTAssertEqual(events.first?.1["data"]?["revision"], result["result"]?["revision"])
      // Normal connection-owned operations remain restricted for root too.
      XCTAssertEqual(
        call(engine, owner, "session.release", .object(["sessionId": survivorID]))["error"]?["code"],
        .string("session_not_owned"))
    }
  }

  func testRootStopAllLeavesDaemonReadyAndStaleIDsCannotStopReplacement() throws {
    var checks = 0
    try withEngine(authorizationVerifier: { _ in checks += 1; return false }) { engine, power, _ in
      let one = peer()
      let two = peer()
      let manager = peer(0)
      let oneID = acquire(engine, one)["result"]!["sessionId"]!
      let twoID = acquire(engine, two)["result"]!["sessionId"]!
      let params = stopParams([oneID, twoID])
      XCTAssertNil(call(engine, manager, "admin.stopSessions", params)["error"])
      XCTAssertEqual(checks, 0)
      XCTAssertEqual(engine.phase, "idle")
      XCTAssertFalse(engine.draining)
      XCTAssertFalse(power.disabled)
      XCTAssertFalse(try engine.state.pending())
      XCTAssertEqual(engine.takeEvents().count, 2)
      let newID = acquire(engine, one)["result"]!["sessionId"]!
      XCTAssertNotEqual(newID, oneID)
      let before = engine.snapshot()
      let repeated = call(engine, manager, "admin.stopSessions", params)
      XCTAssertNil(repeated["error"])
      XCTAssertEqual(repeated["result"]?["stoppedSessionIds"], .array([]))
      XCTAssertEqual(engine.snapshot(), before)
      XCTAssertTrue(power.disabled)
      XCTAssertTrue(engine.takeEvents().isEmpty)
    }
  }

  func testAdminStopCleanupFailureRemainsAnErrorOnRetry() throws {
    try withEngine { engine, power, _ in
      let owner = peer()
      let manager = peer(0)
      let id = acquire(engine, owner)["result"]!["sessionId"]!
      power.failRestore = true
      let params = stopParams([id])
      XCTAssertEqual(
        call(engine, manager, "admin.stopSessions", params)["error"]?["code"],
        .string("recovery_failed"))
      XCTAssertEqual(engine.phase, "degraded")
      XCTAssertTrue(try engine.state.pending())
      let event = engine.takeEvents().first?.1
      XCTAssertEqual(event?["data"]?["reason"], .string("user_stopped"))
      XCTAssertEqual(event?["data"]?["cleanup"], .string("failed"))
      XCTAssertEqual(
        call(engine, manager, "admin.stopSessions", params)["error"]?["code"],
        .string("recovery_failed"))
      XCTAssertEqual(acquire(engine, owner)["error"]?["code"], .string("not_ready"))
    }
  }

  func testAdminStopFailurePreservesUnspecifiedSessionAndReportsUnconfirmedPower() throws {
    try withEngine { engine, power, controls in
      let owner = peer()
      let survivor = peer()
      let manager = peer(0)
      let id = acquire(engine, owner, display: true)["result"]!["sessionId"]!
      let survivorID = acquire(engine, survivor)["result"]!["sessionId"]!
      controls.failRelease = true
      XCTAssertEqual(
        call(engine, manager, "admin.stopSessions", stopParams([id]))["error"]?["code"],
        .string("recovery_failed"))
      XCTAssertEqual(engine.phase, "degraded")
      XCTAssertEqual(engine.sessions.count, 1)
      XCTAssertEqual(engine.sessions[survivor.fd.value]?.id, survivorID.stringValue)
      XCTAssertNil(engine.display)
      XCTAssertTrue(try engine.state.pending())
      XCTAssertEqual(engine.takeEvents().count, 1)
      // A later check exposes any external mismatch while staying degraded;
      // desired=true must not be confused with confirmed inhibition.
      power.disabled = false
      engine.checkPower()
      XCTAssertEqual(engine.phase, "degraded")
      XCTAssertFalse(engine.disabled ?? true)
      XCTAssertEqual(engine.snapshot()["desired"]?["systemSleepDisabled"], .bool(true))
      XCTAssertEqual(engine.sessions.count, 1)
      controls.failRelease = false
      XCTAssertEqual(engine.snapshot()["lastError"]?["code"], .string("recovery_failed"))
      XCTAssertNil(call(engine, survivor, "session.release", .object(["sessionId": survivorID]))["error"])
      XCTAssertFalse(try engine.state.pending())
      XCTAssertEqual(engine.snapshot()["phase"], .string("idle"))
      XCTAssertEqual(engine.snapshot()["lastError"], .null)
    }
  }
}
