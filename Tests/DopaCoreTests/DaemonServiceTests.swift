import CDopa
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
  final class FakeControls: DisplayControls {
    var display = false
    var failRelease = false
    func keepDisplayOn() throws { display = true }
    func releaseDisplay() throws {
      if failRelease { throw DopaError("display release failure") }
      display = false
    }
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
    _ engine: DaemonEngine, _ peer: ServicePeer, display: Bool = false
  ) -> JSONValue {
    call(
      engine, peer, "session.acquire",
      .object(["options": .object(["keepDisplayOn": .bool(display)])])
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
  func testPrepareShutdownRequiresRootAndDrains() throws {
    try withEngine { engine, power, _ in
      let one = peer()
      let two = peer()
      _ = acquire(engine, two)
      XCTAssertTrue(power.disabled)
      XCTAssertTrue(
        call(engine, two, "admin.prepareShutdown")["error"]?["code"] == .string("permission_denied")
      )
      try engine.prepareShutdown()
      XCTAssertTrue(!power.disabled)
      XCTAssertTrue(acquire(engine, one)["error"]?["code"] == .string("shutting_down"))
    }
  }
  func testPowerConflictDoesNotMutate() throws {
    try withEngine { engine, power, _ in
      let one = peer()
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
          "options": .object(["keepDisplayOn": .bool(false)]),
        ]))
      XCTAssertEqual(response["error"]?["code"], .string("invalid_params"))
      XCTAssertTrue(engine.sessions.isEmpty)
      XCTAssertFalse(power.disabled)
    }
  }

  func testBroadcastCoalescesUnsentSnapshotsInOrder() throws {
    // Consecutive broadcasts with no interleaving traffic collapse to
    // the newest snapshot; a response, an ended event boundary, or a sent
    // prefix each disable coalescing for that round and keep order.
    try withEngine { engine, _, _ in
      let sub = peer()
      sub.subscribed = true
      let other = peer()
      _ = acquire(engine, other)
      DaemonService.deliverBroadcast(engine: engine, peers: [sub.fd.value: sub])
      _ = acquire(engine, peer())
      DaemonService.deliverBroadcast(engine: engine, peers: [sub.fd.value: sub])
      var lines = JSONLineBuffer()
      let frames = try lines.append(Data(sub.output[sub.outputOffset...]))
      XCTAssertEqual(frames.count, 1)
      XCTAssertEqual(frames.first?["event"]?.stringValue, "status.changed")
      XCTAssertEqual(frames.first?["data"]?["revision"]?.stringValue, "2")

      // A response in between breaks the exact tail: both snapshots survive
      // around it, newest last.
      let sub2 = peer()
      sub2.subscribed = true
      _ = acquire(engine, peer())
      DaemonService.deliverBroadcast(engine: engine, peers: [sub2.fd.value: sub2])
      sub2.enqueue(call(engine, sub2, "status.get"))
      _ = acquire(engine, peer())
      DaemonService.deliverBroadcast(engine: engine, peers: [sub2.fd.value: sub2])
      var lines2 = JSONLineBuffer()
      let mixed = try lines2.append(Data(sub2.output[sub2.outputOffset...]))
      XCTAssertEqual(mixed.count, 3)
      XCTAssertEqual(mixed[0]["event"]?.stringValue, "status.changed")
      XCTAssertNil(mixed[1]["event"]?.stringValue)
      XCTAssertEqual(mixed[2]["event"]?.stringValue, "status.changed")
      let revisions = [mixed[0], mixed[2]].compactMap { $0["data"]?["revision"]?.stringValue }
      XCTAssertEqual(revisions.count, 2)
      XCTAssertLessThan(Int(revisions[0]) ?? 0, Int(revisions[1]) ?? 0)

      // A partially sent snapshot must never be replaced.
      let sub3 = peer()
      sub3.subscribed = true
      _ = acquire(engine, peer())
      DaemonService.deliverBroadcast(engine: engine, peers: [sub3.fd.value: sub3])
      let firstSize = sub3.queuedBytes
      XCTAssertGreaterThan(firstSize, 20)
      let firstRevision = engine.revision
      sub3.didSend(10)
      _ = acquire(engine, peer())
      let secondRevision = engine.revision
      XCTAssertGreaterThan(secondRevision, firstRevision)
      DaemonService.deliverBroadcast(engine: engine, peers: [sub3.fd.value: sub3])
      // Both frames are present: the sent prefix was not rewritten and the
      // new frame was appended whole. The tail is not frame-aligned at its
      // head (10 bytes already went out), so only the complete trailing
      // frame is decoded.
      let secondLen = sub3.queuedBytes - (firstSize - 10)
      XCTAssertGreaterThan(secondLen, 0)
      XCTAssertEqual(sub3.pendingSnapshotBytes, secondLen)
      var tailLines = JSONLineBuffer()
      let tailFrames = try tailLines.append(Data(sub3.output.suffix(secondLen)))
      XCTAssertEqual(tailFrames.count, 1)
      XCTAssertEqual(
        tailFrames.first?["data"]?["revision"]?.stringValue, String(secondRevision))
    }
  }
  func testSnapshotCoalescingFreesCapSpaceAndStillBounds() {
    // Replacing the tail snapshot releases its bytes before the cap check;
    // a genuinely oversized frame still trips the slow-reader bound.
    let sub = peer()
    sub.enqueueSnapshot(Data(repeating: 1, count: 200_000))
    XCTAssertFalse(sub.dead)
    sub.enqueueSnapshot(Data(repeating: 2, count: 100_000))
    XCTAssertFalse(sub.dead)
    XCTAssertEqual(sub.queuedBytes, 100_000)
    sub.enqueueSnapshot(Data(repeating: 3, count: 300_000))
    XCTAssertTrue(sub.dead)
    XCTAssertLessThanOrEqual(sub.queuedBytes, 262_144)
  }
  func testPollTimeoutComputation() {
    // The run loop sleeps until the earliest timer deadline, socket
    // activity, or stop-pipe wakeup. No peers means no deadlines at all
    // (infinite wait); every deadline class shortens it.
    let now = Date()
    XCTAssertEqual(
      DaemonService.pollTimeoutMilliseconds(
        now: now, nextCheck: now, peers: [:]), -1)
    let active = peer()
    let connected = [active.fd.value: active]
    let power = DaemonService.pollTimeoutMilliseconds(
      now: now, nextCheck: now.addingTimeInterval(1), peers: connected)
    XCTAssertGreaterThan(power, 0)
    XCTAssertLessThanOrEqual(power, 1000)
    let fresh = peer()
    fresh.hello = false
    let hello = DaemonService.pollTimeoutMilliseconds(
      now: now, nextCheck: now.addingTimeInterval(3600), peers: [fresh.fd.value: fresh])
    XCTAssertGreaterThan(hello, 4000)
    // `fresh` is created just after `now`, and positive values round upward.
    XCTAssertLessThanOrEqual(hello, 5001)
    let partial = peer()
    partial.partialSince = now.addingTimeInterval(-2)
    let frame = DaemonService.pollTimeoutMilliseconds(
      now: now, nextCheck: now.addingTimeInterval(3600), peers: [partial.fd.value: partial])
    XCTAssertGreaterThan(frame, 0)
    XCTAssertLessThanOrEqual(frame, 3000)
    XCTAssertEqual(
      DaemonService.pollTimeoutMilliseconds(
        now: now, nextCheck: now.addingTimeInterval(0.000_1), peers: connected),
      1)
  }
  func testStopPipeReadEndIsNonblockingAndCloseOnExec() {
    let descriptor = dopa_stop_fd()
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    XCTAssertNotEqual(fcntl(descriptor, F_GETFL) & O_NONBLOCK, 0)
    XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
  }
  func testBroadcastSkipsEncodeAndConsumesChangeWithoutSubscribers() throws {
    // CLI-only peers (no subscribers) must cause zero notification
    // encodes. The change is consumed because a later subscribe response
    // contains the complete current snapshot; a subsequent change is encoded
    // once and serves any number of subscribers identically.
    try withEngine { engine, _, _ in
      let cli = peer()
      _ = acquire(engine, cli)
      XCTAssertTrue(engine.changed)
      var peers = [cli.fd.value: cli]
      var encodes = 0
      DaemonService.deliverBroadcast(
        engine: engine, peers: peers,
        encode: { value in encodes += 1; return try JSONWire.encode(value) })
      XCTAssertEqual(encodes, 0)
      XCTAssertTrue(cli.output.isEmpty)
      XCTAssertFalse(engine.changed)
      let sub1 = peer()
      sub1.subscribed = true
      let sub2 = peer()
      sub2.subscribed = true
      peers[sub1.fd.value] = sub1
      peers[sub2.fd.value] = sub2
      _ = acquire(engine, peer())
      DaemonService.deliverBroadcast(
        engine: engine, peers: peers,
        encode: { value in encodes += 1; return try JSONWire.encode(value) })
      XCTAssertEqual(encodes, 1)
      XCTAssertFalse(sub1.output.isEmpty)
      XCTAssertEqual(sub1.output, sub2.output)
      XCTAssertTrue(cli.output.isEmpty)
      XCTAssertFalse(engine.changed)
    }
  }
  func testRecoverableWriteErrorsPreserveQueueAndFatalErrorMarksPeerDead() {
    let one = peer()
    one.enqueue(.object(["id": .string("1"), "result": .object([:])]))
    let original = one.output

    XCTAssertEqual(one.flush({ _ in -1 }, errorCode: { EAGAIN }), -1)
    XCTAssertFalse(one.dead)
    XCTAssertEqual(one.outputOffset, 0)
    XCTAssertEqual(one.output, original)

    XCTAssertEqual(one.flush({ _ in -1 }, errorCode: { EINTR }), -1)
    XCTAssertFalse(one.dead)
    XCTAssertEqual(one.outputOffset, 0)
    XCTAssertEqual(one.output, original)

    XCTAssertEqual(one.flush({ _ in -1 }, errorCode: { EPIPE }), -1)
    XCTAssertTrue(one.dead)
    XCTAssertEqual(one.outputOffset, 0)
    XCTAssertEqual(one.output, original)
  }
  func testSlowSocketBackpressurePreservesOrderAndQueueBound() throws {
    var sockets = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    guard sockets[0] >= 0, sockets[1] >= 0 else { return }
    let writerFD = sockets[0]
    let readerFD = sockets[1]
    defer { Darwin.close(readerFD) }
    let flags = fcntl(writerFD, F_GETFL)
    XCTAssertGreaterThanOrEqual(flags, 0)
    XCTAssertEqual(fcntl(writerFD, F_SETFL, flags | O_NONBLOCK), 0)
    var sendBuffer: Int32 = 1_024
    XCTAssertEqual(
      setsockopt(
        writerFD, SOL_SOCKET, SO_SNDBUF, &sendBuffer,
        socklen_t(MemoryLayout<Int32>.size)),
      0)

    let slow = ServicePeer(fd: Descriptor(writerFD), uid: 501, pid: getpid())
    let payload = String(repeating: "x", count: 8_000)
    for sequence in 0..<24 {
      slow.enqueue(.object([
        "id": .string(String(sequence)),
        "result": .object(["payload": .string(payload)]),
      ]))
    }
    XCTAssertFalse(slow.dead)
    XCTAssertLessThanOrEqual(slow.queuedBytes, 262_144)
    let expected = slow.output

    var hitBackpressure = false
    while !slow.isEmpty {
      let result = slow.flush { raw in
        Darwin.write(writerFD, raw.baseAddress, raw.count)
      }
      if result < 0 {
        XCTAssertEqual(errno, EAGAIN)
        hitBackpressure = true
        break
      }
      XCTAssertGreaterThan(result, 0)
    }
    XCTAssertTrue(hitBackpressure)
    XCTAssertFalse(slow.dead)
    XCTAssertGreaterThan(slow.queuedBytes, 0)

    var received = Data()
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while !slow.isEmpty {
      let count = Darwin.read(readerFD, &bytes, bytes.count)
      XCTAssertGreaterThan(count, 0)
      received.append(contentsOf: bytes.prefix(count))
      while !slow.isEmpty {
        let result = slow.flush { raw in
          Darwin.write(writerFD, raw.baseAddress, raw.count)
        }
        if result < 0 {
          XCTAssertEqual(errno, EAGAIN)
          XCTAssertFalse(slow.dead)
          break
        }
        XCTAssertGreaterThan(result, 0)
      }
    }
    XCTAssertEqual(shutdown(writerFD, SHUT_WR), 0)
    while true {
      let count = Darwin.read(readerFD, &bytes, bytes.count)
      if count == 0 { break }
      XCTAssertGreaterThan(count, 0)
      received.append(contentsOf: bytes.prefix(count))
    }
    XCTAssertEqual(received, expected)
    var lines = JSONLineBuffer()
    XCTAssertEqual(
      try lines.append(received).compactMap { $0["id"]?.stringValue },
      (0..<24).map(String.init))
  }
  func testOutputOffsetPartialWriteCapAndOrder() {
    // Partial writes expose only undelivered bytes in order, the 256 KiB
    // cap counts undelivered bytes (not the drained prefix), the drained
    // prefix compacts past 64 KiB, and full drain releases storage.
    let p = peer()
    p.enqueue(.object(["id": .string("1"), "result": .object(["a": .number(1)])]))
    p.enqueue(.object(["id": .string("2"), "result": .object(["b": .number(2)])]))
    let total = p.queuedBytes
    XCTAssertGreaterThan(total, 0)
    var head: [UInt8] = []
    XCTAssertEqual(p.writeSlice { raw in head = Array(raw.prefix(10)); return min(10, raw.count) }, 10)
    p.didSend(10)
    XCTAssertEqual(p.queuedBytes, total - 10)
    XCTAssertFalse(p.isEmpty)
    var rest: [UInt8] = []
    while !p.isEmpty {
      let n = p.writeSlice { raw in rest.append(contentsOf: raw); return raw.count }
      XCTAssertGreaterThan(n, 0)
      p.didSend(n)
    }
    XCTAssertTrue(p.isEmpty)
    XCTAssertEqual(p.queuedBytes, 0)
    XCTAssertEqual(p.outputOffset, 0)
    var line = JSONLineBuffer()
    let frames = try? line.append(Data(head + rest))
    XCTAssertEqual(frames?.compactMap { $0["id"]?.stringValue }, ["1", "2"])

    let slow = peer()
    let big = JSONValue.object(["event": .string("x"), "data": .string(String(repeating: "y", count: 60_000))])
    for _ in 0..<4 { slow.enqueue(big) }
    XCTAssertFalse(slow.dead)
    let queued4 = slow.queuedBytes
    // Drain 100 KiB: the drained prefix compacts once past 64 KiB and stays
    // bounded afterwards; the cap counts only undelivered bytes.
    var drained = 0
    while drained < 100 * 1024 {
      let n = slow.writeSlice { raw in min(16_384, raw.count) }
      slow.didSend(n)
      drained += n
    }
    XCTAssertLessThanOrEqual(slow.outputOffset, 65_536)
    XCTAssertEqual(slow.queuedBytes, slow.output.count - slow.outputOffset)
    XCTAssertEqual(slow.queuedBytes, queued4 - drained)
    // Drained bytes must not count toward the cap: keep accepting until the
    // slow reader trips it, then show accepted + drained exceeds the limit.
    var accepted = 0
    while !slow.dead, accepted < 10 {
      slow.enqueue(big)
      if !slow.dead { accepted += 1 }
    }
    XCTAssertTrue(slow.dead)
    XCTAssertLessThanOrEqual(slow.queuedBytes, 262_144)
    // Total bytes ever accepted exceed the cap: only possible because drained
    // bytes are excluded from the 256 KiB accounting.
    let frameSize = (try? JSONWire.encode(big))?.count ?? 60_000
    XCTAssertGreaterThan(queued4 + accepted * frameSize, 262_144)
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
      let compatible = peer()
      compatible.hello = false
      let hello = call(
        engine, compatible, "hello",
        .object([
          "apiVersion": .number(1),
          "client": .object(["name": .string("test"), "version": .string("1")]),
        ]))
      XCTAssertEqual(hello["result"]?["daemonVersion"], .string(DopaProtocol.appVersion))
      let two = peer()
      XCTAssertEqual(
        call(
          engine, two, "session.acquire",
          .object([
            "options": .object([
              "keepDisplayOn": .bool(false), "unexpectedPolicy": .bool(true),
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
