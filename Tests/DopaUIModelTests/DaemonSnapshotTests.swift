import DopaProtocol
import Foundation
import XCTest

@testable import DopaUIModel

final class DaemonSnapshotTests: XCTestCase {
  func testPublicInitializerAllowsUnknownFieldsAndMapsConfirmedValues() throws {
    let value = snapshotJSON(
      instanceID: "daemon-a",
      revision: "42",
      phase: "active",
      sessions: [sessionJSON(id: "ui", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false,
      extras: [
        "futureField": .object([
          "newShape": .array([.string("kept opaque"), .number(99)])
        ]),
        "anotherFutureFlag": .bool(true),
      ]
    )

    let snapshot = try DaemonSnapshot(value)

    XCTAssertEqual(snapshot.instanceID, "daemon-a")
    XCTAssertEqual(snapshot.revision, "42")
    XCTAssertEqual(snapshot.phase, "active")
    XCTAssertEqual(snapshot.sessions.map(\.id), ["ui"])
    XCTAssertEqual(snapshot.sessions[0].clientName, "Dopa UI")
    XCTAssertEqual(snapshot.sessions[0].peerPID, 2187)
    XCTAssertEqual(snapshot.systemSleepDisabled, true)
    XCTAssertEqual(snapshot.keepDisplayOn, false)
    XCTAssertTrue(snapshot.isConfirmed)
  }

  func testRevisionOrderingUsesDecimalStringsWithoutFloatingPointLoss() throws {
    let previous = try DaemonSnapshot(snapshotJSON(
      revision: "999999999999999999999999999999999999999999999999"))
    let newer = try DaemonSnapshot(snapshotJSON(
      revision: "1000000000000000000000000000000000000000000000000"))
    let padded = try DaemonSnapshot(snapshotJSON(revision: "0000000000000000000000000000000000042"))
    let plain = try DaemonSnapshot(snapshotJSON(revision: "42"))
    let restarted = try DaemonSnapshot(snapshotJSON(instanceID: "daemon-b", revision: "1"))

    XCTAssertTrue(newer.isAtLeastAsNew(as: previous))
    XCTAssertFalse(previous.isAtLeastAsNew(as: newer))
    XCTAssertTrue(padded.isAtLeastAsNew(as: plain))
    XCTAssertTrue(plain.isAtLeastAsNew(as: padded))
    XCTAssertTrue(restarted.isAtLeastAsNew(as: newer), "a new daemon instance starts a new revision sequence")
  }

  func testConfirmedDistinguishesValidIdleActiveAndUnknownReadbacks() throws {
    let idle = try DaemonSnapshot(snapshotJSON(
      phase: "idle", systemSleepDisabled: false, keepDisplayOn: false))
    let active = try DaemonSnapshot(snapshotJSON(
      phase: "active",
      sessions: [sessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281, keepDisplayOn: true)],
      systemSleepDisabled: true,
      keepDisplayOn: true
    ))
    let mismatched = try DaemonSnapshot(snapshotJSON(
      phase: "active",
      sessions: [sessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281)],
      systemSleepDisabled: false,
      keepDisplayOn: false
    ))
    let missingReadback = try DaemonSnapshot(snapshotJSON(
      phase: "idle", systemSleepDisabled: false, keepDisplayOn: nil))
    let recoveryPending = try DaemonSnapshot(snapshotJSON(
      phase: "idle", systemSleepDisabled: false, keepDisplayOn: false, recoveryPending: true))

    XCTAssertTrue(idle.isConfirmed)
    XCTAssertTrue(active.isConfirmed)
    XCTAssertFalse(mismatched.isConfirmed)
    XCTAssertFalse(missingReadback.isConfirmed)
    XCTAssertFalse(recoveryPending.isConfirmed)
  }
}

private func snapshotJSON(
  instanceID: String = "daemon-a",
  revision: String = "1",
  phase: String = "idle",
  sessions: [JSONValue] = [],
  systemSleepDisabled: Bool? = false,
  keepDisplayOn: Bool? = false,
  recoveryPending: Bool = false,
  extras: [String: JSONValue] = [:]
) -> JSONValue {
  var confirmed: [String: JSONValue] = [:]
  if let systemSleepDisabled { confirmed["systemSleepDisabled"] = .bool(systemSleepDisabled) }
  if let keepDisplayOn { confirmed["keepDisplayOn"] = .bool(keepDisplayOn) }

  var object: [String: JSONValue] = [
    "instanceId": .string(instanceID),
    "revision": .string(revision),
    "phase": .string(phase),
    "sessions": .array(sessions),
    "recoveryPending": .bool(recoveryPending),
    "confirmed": .object(confirmed),
  ]
  for (key, value) in extras { object[key] = value }
  return .object(object)
}

private func sessionJSON(
  id: String,
  clientName: String,
  pid: Int32,
  keepDisplayOn: Bool = false,
  stopOnLidClose: Bool = false
) -> JSONValue {
  .object([
    "id": .string(id),
    "clientName": .string(clientName),
    "peerPID": .number(Double(pid)),
    "options": .object([
      "keepDisplayOn": .bool(keepDisplayOn),
      "stopOnLidClose": .bool(stopOnLidClose),
    ]),
  ])
}

extension DaemonSnapshotTests {
  func testPeerUIDAllowsMissingLegacyFieldAndStrictlyValidatesPresentValues() throws {
    let original = sessionJSON(id: "a", clientName: "CLI", pid: 10)
    XCTAssertNil(try DaemonSnapshot(snapshotJSON(sessions: [original])).sessions[0].peerUID)
    for uid in [UInt32(0), 501, UInt32.max] {
      var session = original.objectValue!
      session["peerUID"] = .number(Double(uid))
      XCTAssertEqual(try DaemonSnapshot(snapshotJSON(sessions: [.object(session)])).sessions[0].peerUID, uid)
    }
    for invalid: JSONValue in [.null, .string("501"), .bool(true), .number(-1), .number(0.5), .number(4_294_967_296)] {
      var session = original.objectValue!
      session["peerUID"] = invalid
      XCTAssertThrowsError(try DaemonSnapshot(snapshotJSON(sessions: [.object(session)])))
    }
  }
}
