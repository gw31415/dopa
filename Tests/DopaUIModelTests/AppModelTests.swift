import DopaClient
import DopaAuthorization
import DopaProtocol
import Foundation
import Observation
import XCTest

@testable import DopaUIModel

@available(macOS 14.0, *)
@MainActor
final class AppModelTests: XCTestCase {
  func testIdenticalSnapshotDoesNotPublishObservationChange() async throws {
    let idle = modelSnapshotJSON()
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    let model = AppModel(transport: transport)
    try await model.connectOnce()

    let changed = expectation(description: "identical snapshot must not be republished")
    changed.isInverted = true
    withObservationTracking {
      _ = model.snapshot
    } onChange: {
      changed.fulfill()
    }
    await transport.enqueue(.object([
      "event": .string("status.changed"),
      "data": .object(["snapshot": idle]),
    ]))
    try await model.pollOnce()
    await fulfillment(of: [changed], timeout: 0.1)
  }

  func testStartingDurationPublishesMatchingClockBeforeStatusRefreshCompletes() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    model.editDuration("01:20:00")
    await model.advanceClock(to: Date().addingTimeInterval(-0.25))
    await transport.setStatusGetHeld(true)
    let beforeStart = Date()

    let startTask = Task { @MainActor in await model.start() }
    await transport.waitUntilStatusGetStarted()

    XCTAssertTrue(model.schedule.running)
    XCTAssertGreaterThanOrEqual(model.now, beforeStart)
    let remaining = model.schedule.deadline?.timeIntervalSince(model.now)
    XCTAssertEqual(remaining, 4_800)
    XCTAssertEqual(remaining.map { Int(ceil($0)) }, 4_800)

    await transport.releaseStatusGet()
    await startTask.value
  }

  func testClockDelayRestsOnlyWhenHiddenAndSessionless() async throws {
    // Visible panels tick every second; hidden panels rest 30s without
    // duties, or wait toward a finite deadline. processClockTick already
    // returns early when hidden and sessionless, and setPresentationActive
    // refreshes `now` on return.
    let idle = modelSnapshotJSON(phase: "idle")
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    let model = AppModel(transport: transport)
    XCTAssertEqual(model.clockWait(), .interval(30_000_000_000))
    model.setPresentationActive(true)
    XCTAssertEqual(model.clockWait(), .interval(1_000_000_000))
    model.setPresentationActive(false)
    XCTAssertEqual(model.clockWait(), .interval(30_000_000_000))
    try await model.connectOnce()
    await model.start()
    XCTAssertNotNil(model.ownSessionID)
    // The default schedule starts finite, so the hidden ticker already waits
    // wall-anchored instead of ticking.
    guard case .wallUntil(let initial) = model.clockWait() else {
      return XCTFail("started hidden session must wait wall-anchored")
    }
    XCTAssertGreaterThan(initial.timeIntervalSinceNow, 0)
    model.editDuration("00:10:00")
    model.applyEdit()
    guard case .wallUntil(let deadline) = model.clockWait() else {
      return XCTFail("finite hidden deadline must wait wall-anchored")
    }
    XCTAssertEqual(deadline.timeIntervalSinceNow, 600, accuracy: 30)
    // Unlimited hidden ownership has no deadline to enforce: rest. Stopped
    // unlimited mode applies immediately, so stop, switch, and start again.
    await model.stop()
    XCTAssertNil(model.ownSessionID)
    model.setUnlimited(true)
    await model.start()
    XCTAssertNotNil(model.ownSessionID)
    XCTAssertNil(model.schedule.deadline)
    XCTAssertEqual(model.clockWait(), .interval(30_000_000_000))
  }

  func testApplyingDurationPublishesMatchingClockWithoutWaitingForTick() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    model.editDuration("01:20:00")
    await model.advanceClock(to: Date().addingTimeInterval(-0.25))
    let beforeApply = Date()

    model.applyEdit()

    XCTAssertNil(model.schedule.draft)
    XCTAssertGreaterThanOrEqual(model.now, beforeApply)
    let remaining = model.schedule.deadline?.timeIntervalSince(model.now)
    XCTAssertEqual(remaining, 4_800)
    XCTAssertEqual(remaining.map { Int(ceil($0)) }, 4_800)
  }

  func testEditIntentBasisForwardsFreezingAndPreservesInvalidDraft() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    let model = AppModel(transport: transport)
    model.beginEditingBasis(.end)
    XCTAssertEqual(model.schedule.basis, .end)
    let fixed = model.schedule.config
    model.beginEditingBasis(.end)
    XCTAssertEqual(model.schedule.config, fixed)
    model.editDuration("invalid")
    let invalid = model.schedule
    model.beginEditingBasis(.end)
    XCTAssertEqual(model.schedule, invalid)
    model.setUnlimited(true)
    let unlimited = model.schedule
    model.beginEditingBasis(.end)
    model.addTime(900)
    XCTAssertEqual(model.schedule, unlimited)
  }

  func testDateSelectionForwardsExactValueAndKeepsInvalidSelectionVisible() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    let selected = Date().addingTimeInterval(3600.375)
    model.editEndDate(selected)
    XCTAssertEqual(model.schedule.config, .end(selected))
    XCTAssertNil(model.schedule.draft)

    let past = Date().addingTimeInterval(-60)
    model.editEndDate(past)
    XCTAssertEqual(model.schedule.draft?.end, past)
    XCTAssertEqual(model.schedule.draft?.error, .expiredEndTime)
    XCTAssertEqual(model.schedule.config, .end(selected))
    XCTAssertFalse(model.canStart)
    model.cancelEdit()
    XCTAssertEqual(model.schedule.config, .end(selected))
  }

  func testDisconnectIsNotReportedAsOffAndReconnectDoesNotAcquireAgain() async throws {
    let running = modelSnapshotJSON(
      phase: "active",
      sessions: [modelSessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(running)),
      statusValue: running
    )
    let model = AppModel(transport: transport)

    try await model.connectOnce()
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.status, "他プロセスで動作中")

    await transport.setPollFailure(.disconnected)
    do {
      try await model.pollOnce()
      XCTFail("pollOnce should surface a transport failure")
    } catch {
      // The model updates its state before propagating the failed poll.
    }

    XCTAssertEqual(model.connectionState, .disconnected)
    XCTAssertNil(model.snapshot)
    XCTAssertEqual(model.status, "接続を確認できません")
    XCTAssertNotEqual(model.status, "オフ")

    await transport.setPollFailure(nil)
    try await model.connectOnce()

    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.status, "他プロセスで動作中")
    let methods = await transport.requestMethods()
    let connectCount = await transport.connectCount()
    XCTAssertFalse(methods.contains("session.acquire"), "reconnect must only observe the daemon")
    XCTAssertEqual(connectCount, 2)
  }

  func testRejectedOptionUpdateKeepsAppliedOptionsAndDraft() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertEqual(model.ownSessionID, "own")

    let originalOptions = model.options
    model.editDuration("00:30:00")
    XCTAssertNotNil(model.schedule.draft)
    await transport.setOptionFailure(true)

    await model.setOptions(SessionOptions(keepDisplayOn: true, stopOnLidClose: true))

    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.options, originalOptions)
    XCTAssertNotNil(model.schedule.draft)
    XCTAssertNotNil(model.message)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.update"))
    XCTAssertTrue(methods.contains("status.get"), "a rejected update refreshes the confirmed state")
  }

  func testOwnedSessionEndedEventStopsScheduleAndDiscardsDraft() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertEqual(model.ownSessionID, "own")

    model.editDuration("00:30:00")
    XCTAssertNotNil(model.schedule.draft)
    await transport.enqueue(.object([
      "event": .string("session.ended"),
      "data": .object([
        "sessionId": .string("own"),
        "reason": .string("user_stopped"),
        "cleanup": .string("confirmed"),
        "revision": .string("3"),
      ]),
    ]))

    try await model.pollOnce()

    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
    XCTAssertNil(model.schedule.draft)
    XCTAssertEqual(model.message, "全体管理の操作により停止しました。")
  }

  func testExpiryReleasesWhileExternalAuthorizationIsStillPending() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [
        modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187),
        modelSessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281),
      ],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(
        capabilities: ["admin.stopSessions"], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let authorization = AuthorizationSuspension()
    let model = AppModel(
      transport: transport,
      authorize: { try await authorization.request() }
    )
    try await model.connectOnce()
    await model.start()
    let deadline = try XCTUnwrap(model.schedule.deadline)
    XCTAssertEqual(model.ownSessionID, "own")

    let adminTask = Task { @MainActor in
      await model.stopSessions(["cli"])
    }
    await authorization.waitUntilStarted()
    XCTAssertTrue(model.authorizing)
    XCTAssertFalse(model.busy, "the authentication prompt must not block the local clock")

    await model.advanceClock(to: deadline.addingTimeInterval(1))

    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.release"))

    await authorization.succeed()
    await adminTask.value
    XCTAssertFalse(model.authorizing)
  }

  func testHiddenClockDoesNotPublishTicksButStillExpiresOwnSession() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    let published = model.now
    let deadline = try XCTUnwrap(model.schedule.deadline)

    await model.processClockTick(at: deadline.addingTimeInterval(-1))

    XCTAssertEqual(model.now, published)
    XCTAssertEqual(model.ownSessionID, "own")

    await model.processClockTick(at: deadline.addingTimeInterval(1))

    XCTAssertEqual(model.now, deadline.addingTimeInterval(1))
    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
  }

  func testVisibleClockPublishesTicks() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let model = AppModel(transport: MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle))
    model.setPresentationActive(true)
    let tick = Date().addingTimeInterval(10)

    await model.processClockTick(at: tick)

    XCTAssertEqual(model.now, tick)
    model.setPresentationActive(false)
  }

  func testHiddenClockSkipsDisplayChurnBeforeDeadline() async throws {
    // A hidden panel with a future deadline publishes no `now` churn;
    // becoming visible resumes publishing. Enforcement is unchanged.
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    let published = model.now
    let deadline = try XCTUnwrap(model.schedule.deadline)

    await model.advanceClock(to: deadline.addingTimeInterval(-10))

    XCTAssertEqual(model.now, published)
    XCTAssertEqual(model.ownSessionID, "own")

    model.setPresentationActive(true)
    let tick = deadline.addingTimeInterval(-5)
    await model.advanceClock(to: tick)

    XCTAssertEqual(model.now, tick)
    model.setPresentationActive(false)
  }

  func testStalePollSnapshotCannotClearOwnedIDAfterAcquire() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()

    await transport.setPollHeld(true)
    let pollTask = Task { @MainActor in
      try? await model.pollOnce()
    }
    await transport.waitUntilPollStarted()

    await transport.setStatusGetHeld(true)
    let startTask = Task { @MainActor in
      await model.start()
    }
    await transport.waitUntilStatusGetStarted()
    XCTAssertEqual(model.ownSessionID, "own", "the acquire response is already applied")

    let stale = modelSnapshotJSON(revision: "1", phase: "idle")
    let event = JSONValue.object([
      "event": .string("status.changed"),
      "data": .object(["snapshot": stale]),
    ])
    await transport.releasePoll(with: [event])
    await pollTask.value

    XCTAssertEqual(model.ownSessionID, "own")
    XCTAssertEqual(model.snapshot?.revision, "1")

    await transport.releaseStatusGet()
    await startTask.value
    XCTAssertEqual(model.ownSessionID, "own")
    XCTAssertEqual(model.snapshot?.revision, "3")
  }

  func testFailedReleaseKeepsSecondShutdownBlockedAfterDegradedEmptySnapshot() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let degraded = modelSnapshotJSON(
      revision: "5",
      phase: "degraded",
      sessions: [],
      systemSleepDisabled: false,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running
    )
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertEqual(model.ownSessionID, "own")

    await transport.setStatusValue(degraded)
    await transport.setReleaseFailure(true)

    let firstShutdown = await model.shutdown()
    XCTAssertFalse(firstShutdown)
    XCTAssertNil(model.ownSessionID)
    XCTAssertEqual(model.snapshot?.phase, "degraded")
    XCTAssertTrue(model.cleanupUnconfirmed)

    let secondShutdown = await model.shutdown()
    XCTAssertFalse(secondShutdown)
    let methods = await transport.requestMethods()
    XCTAssertEqual(methods.filter { $0 == "session.release" }.count, 1)
  }

  func testCancelledAuthorizationLeavesSnapshotAndSessionsUntouched() async throws {
    let active = modelSnapshotJSON(
      revision: "3",
      phase: "active",
      sessions: [modelSessionJSON(id: "cli", clientName: "dopa CLI", pid: 4281)],
      systemSleepDisabled: true,
      keepDisplayOn: false
    )
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(
        capabilities: ["admin.stopSessions"], snapshot: try DaemonSnapshot(active)),
      statusValue: active
    )
    let authorization = AuthorizationSuspension()
    let model = AppModel(
      transport: transport,
      authorize: { try await authorization.request() }
    )
    try await model.connectOnce()
    let before = try XCTUnwrap(model.snapshot)

    let stopTask = Task { @MainActor in
      await model.stopSessions(["cli"])
    }
    await authorization.waitUntilStarted()
    XCTAssertTrue(model.authorizing)
    await authorization.cancel()
    await stopTask.value

    XCTAssertFalse(model.authorizing)
    XCTAssertFalse(model.busy)
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.snapshot, before)
    XCTAssertEqual(model.sessions.map(\.id), ["cli"])
    let methods = await transport.requestMethods()
    XCTAssertFalse(methods.contains("admin.stopSessions"))
    XCTAssertNil(model.message)
  }

  func testStoppingOnlyOwnSessionNeedsNeitherAdminCapabilityNorAuthorization() async throws {
    let idle = modelSnapshotJSON(phase: "idle")
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true, keepDisplayOn: false)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied })
    try await model.connectOnce()
    await model.start()
    XCTAssertTrue(model.canStopAll)
    await transport.setStatusValue(modelSnapshotJSON(revision: "4", phase: "idle"))
    await model.stopSessions(["own"])
    XCTAssertNil(model.ownSessionID)
    XCTAssertEqual(model.connectionState, .connected)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.release"))
    XCTAssertFalse(methods.contains("admin.stopSessions"))
  }
}

private actor MockDaemonTransport: DaemonTransport {
  enum Failure: Error, Sendable {
    case disconnected
  }

  struct Request: Sendable {
    let method: String
    let params: JSONValue
  }

  private let handshake: DaemonHandshake
  private var statusValue: JSONValue
  private var events: [JSONValue] = []
  private var pollCalls = 0
  private var holdConnect = false
  private var failingConnectAttempts: Set<Int> = []
  private var connectStarted = false
  private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var connectContinuations: [CheckedContinuation<Void, Never>] = []
  private var emptyPollDelayNanoseconds: UInt64? = 20_000_000
  private var pollFailure: Failure?
  private var optionFailure = false
  private var releaseFailure = false
  private var requests: [Request] = []
  private var connects = 0
  private var closes = 0
  private var holdClose = false
  private var closeStarted = false
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var closeContinuation: CheckedContinuation<Void, Never>?
  private var holdPoll = false
  private var pollStarted = false
  private var pollStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var pollContinuation: CheckedContinuation<[JSONValue], Error>?
  private var holdStatusGet = false
  private var statusGetStarted = false
  private var statusGetStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var statusGetContinuation: CheckedContinuation<JSONValue, Error>?

  init(handshake: DaemonHandshake, statusValue: JSONValue) {
    self.handshake = handshake
    self.statusValue = statusValue
  }

  func connect() async throws -> DaemonHandshake {
    connects += 1
    let attempt = connects
    if holdConnect {
      connectStarted = true
      let waiters = connectStartWaiters
      connectStartWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        connectContinuations.append(continuation)
      }
    }
    if failingConnectAttempts.remove(attempt) != nil { throw Failure.disconnected }
    return handshake
  }

  func request(method: String, params: JSONValue) async throws -> JSONValue {
    requests.append(Request(method: method, params: params))
    switch method {
    case "status.get":
      if holdStatusGet {
        statusGetStarted = true
        let waiters = statusGetStartWaiters
        statusGetStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
          statusGetContinuation = continuation
        }
      }
      return statusValue
    case "session.acquire":
      return .object(["sessionId": .string("own"), "revision": .string("2")])
    case "session.update":
      if optionFailure {
        throw DopaRemoteError(code: "permission_denied", message: "fixture rejected options")
      }
      return .object(["revision": .string("4")])
    case "session.release":
      if releaseFailure {
        throw DopaRemoteError(code: "recovery_failed", message: "fixture could not confirm cleanup")
      }
      return .object(["revision": .string("4")])
    case "admin.stopSessions", "session.stopSessions":
      return .object(["revision": .string("5")])
    default:
      return .object([:])
    }
  }

  func poll() async throws -> [JSONValue] {
    pollCalls += 1
    if let pollFailure { throw pollFailure }
    if holdPoll {
      pollStarted = true
      let waiters = pollStartWaiters
      pollStartWaiters.removeAll()
      waiters.forEach { $0.resume() }
      return try await withCheckedThrowingContinuation { continuation in
        pollContinuation = continuation
      }
    }
    let next = events
    events.removeAll()
    if next.isEmpty, let emptyPollDelayNanoseconds {
      // Model the blocking production transport: an empty poll waits a
      // moment instead of returning instantly, so monitoring-loop tests do
      // not busy-spin while connected.
      try await Task.sleep(nanoseconds: emptyPollDelayNanoseconds)
    }
    return next
  }

  func close() async {
    closes += 1
    if holdClose {
      closeStarted = true
      let waiters = closeWaiters
      closeWaiters.removeAll()
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { continuation in
        closeContinuation = continuation
      }
    }
  }

  func setPollFailure(_ failure: Failure?) {
    pollFailure = failure
  }

  func setOptionFailure(_ enabled: Bool) {
    optionFailure = enabled
  }

  func setReleaseFailure(_ enabled: Bool) {
    releaseFailure = enabled
  }

  func setStatusValue(_ value: JSONValue) {
    statusValue = value
  }

  func setPollHeld(_ held: Bool) {
    holdPoll = held
  }

  func waitUntilPollStarted() async {
    if pollStarted { return }
    await withCheckedContinuation { continuation in
      pollStartWaiters.append(continuation)
    }
  }

  func releasePoll(with values: [JSONValue] = []) {
    events.append(contentsOf: values)
    holdPoll = false
    guard let continuation = pollContinuation else { return }
    pollContinuation = nil
    let next = events
    events.removeAll()
    continuation.resume(returning: next)
  }

  func setStatusGetHeld(_ held: Bool) {
    holdStatusGet = held
  }

  func waitUntilStatusGetStarted() async {
    if statusGetStarted { return }
    await withCheckedContinuation { continuation in
      statusGetStartWaiters.append(continuation)
    }
  }

  func releaseStatusGet() {
    holdStatusGet = false
    guard let continuation = statusGetContinuation else { return }
    statusGetContinuation = nil
    continuation.resume(returning: statusValue)
  }

  func enqueue(_ event: JSONValue) {
    events.append(event)
  }

  func requestMethods() -> [String] {
    requests.map(\.method)
  }

  func connectCount() -> Int {
    connects
  }

  func setConnectHeld(_ held: Bool) {
    holdConnect = held
  }

  func failConnect(attempt: Int) {
    failingConnectAttempts.insert(attempt)
  }

  func waitUntilConnectStarted() async {
    if connectStarted { return }
    await withCheckedContinuation { continuation in
      connectStartWaiters.append(continuation)
    }
  }

  func releaseConnect() {
    holdConnect = false
    let continuations = connectContinuations
    connectContinuations.removeAll()
    for continuation in continuations { continuation.resume() }
  }

  func pollCount() -> Int { pollCalls }

  func setEmptyPollDelayNanoseconds(_ value: UInt64?) {
    emptyPollDelayNanoseconds = value
  }

  func closeCount() -> Int {
    closes
  }

  func setCloseHeld(_ held: Bool) {
    holdClose = held
  }

  func waitUntilCloseStarted() async {
    if closeStarted { return }
    await withCheckedContinuation { continuation in
      closeWaiters.append(continuation)
    }
  }

  func releaseClose() {
    holdClose = false
    guard let continuation = closeContinuation else { return }
    closeContinuation = nil
    continuation.resume()
  }
}

/// Models a protocol-compatible transport whose first close snapshots its
/// current connection, then suspends. A concurrent handshake can finish after
/// that snapshot and install a new connection, so AppModel must close again
/// after the pending close completes.
private actor LateInstallingTransport: DaemonTransport {
  private let handshake: DaemonHandshake
  private var connectContinuation: CheckedContinuation<Void, Never>?
  private var closeContinuations: [CheckedContinuation<Void, Never>] = []
  private var connectStarted = false
  private var connectWaiters: [CheckedContinuation<Void, Never>] = []
  private var closeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var connected = false
  private var closes = 0

  init(handshake: DaemonHandshake) {
    self.handshake = handshake
  }

  func connect() async throws -> DaemonHandshake {
    connectStarted = true
    let waiters = connectWaiters
    connectWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      connectContinuation = continuation
    }
    connected = true
    return handshake
  }

  func request(method: String, params: JSONValue) async throws -> JSONValue {
    guard connected else { throw MockDaemonTransport.Failure.disconnected }
    return .object([:])
  }

  func poll() async throws -> [JSONValue] { [] }

  func close() async {
    closes += 1
    // This assignment represents the connection snapshot taken by close.
    // A handshake released below can install after it while this call waits.
    connected = false
    let ready = closeWaiters.filter { $0.count <= closes }
    closeWaiters.removeAll { $0.count <= closes }
    for waiter in ready { waiter.continuation.resume() }
    await withCheckedContinuation { continuation in
      closeContinuations.append(continuation)
    }
  }

  func waitUntilConnectStarted() async {
    if connectStarted { return }
    await withCheckedContinuation { continuation in connectWaiters.append(continuation) }
  }

  func waitUntilCloseStarted(count: Int = 1) async {
    if closes >= count { return }
    await withCheckedContinuation { continuation in
      closeWaiters.append((count, continuation))
    }
  }

  func releaseConnect() {
    let continuation = connectContinuation
    connectContinuation = nil
    continuation?.resume()
  }

  func releaseClose() {
    guard !closeContinuations.isEmpty else { return }
    closeContinuations.removeFirst().resume()
  }

  func isConnected() -> Bool { connected }
  func closeCount() -> Int { closes }
}

private actor AuthorizationSuspension {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<ManagementCredential, Error>?

  func request() async throws -> ManagementCredential {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func succeed() {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(returning: ManagementCredential(externalForm: "fixture-credential"))
  }

  func cancel() {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(throwing: DopaAuthorizationError.cancelled)
  }
}

private func modelSnapshotJSON(
  instanceID: String = "daemon-a",
  revision: String = "1",
  phase: String = "idle",
  sessions: [JSONValue] = [],
  systemSleepDisabled: Bool? = false,
  keepDisplayOn: Bool? = false,
  recoveryPending: Bool = false
) -> JSONValue {
  var confirmed: [String: JSONValue] = [:]
  if let systemSleepDisabled { confirmed["systemSleepDisabled"] = .bool(systemSleepDisabled) }
  if let keepDisplayOn { confirmed["keepDisplayOn"] = .bool(keepDisplayOn) }
  return .object([
    "instanceId": .string(instanceID),
    "revision": .string(revision),
    "phase": .string(phase),
    "sessions": .array(sessions),
    "recoveryPending": .bool(recoveryPending),
    "confirmed": .object(confirmed),
  ])
}

private func modelSessionJSON(
  id: String,
  clientName: String,
  pid: Int32,
  keepDisplayOn: Bool = false,
  stopOnLidClose: Bool = false,
  peerUID: UInt32? = nil
) -> JSONValue {
  var fields: [String: JSONValue] = [
    "id": .string(id),
    "clientName": .string(clientName),
    "peerPID": .number(Double(pid)),
    "options": .object([
      "keepDisplayOn": .bool(keepDisplayOn),
      "stopOnLidClose": .bool(stopOnLidClose),
    ]),
  ]
  if let peerUID { fields["peerUID"] = .number(Double(peerUID)) }
  return .object(fields)
}

@available(macOS 14.0, *)
@MainActor
extension AppModelTests {
  func testSameUIDStopsUseUnprivilegedCapabilityWithoutAuthorization() async throws {
    let active = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "a", clientName: "CLI", pid: 1, peerUID: 501),
      modelSessionJSON(id: "b", clientName: "CLI", pid: 2, peerUID: 501)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["session.stopSessions", "admin.stopSessions"], snapshot: try DaemonSnapshot(active)),
      statusValue: modelSnapshotJSON(revision: "5"))
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied }, currentUID: 501)
    try await model.connectOnce()
    XCTAssertTrue(model.canStopAll)
    await model.stopSessions(["a", "b"])
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.stopSessions"))
    XCTAssertFalse(methods.contains("admin.stopSessions"))
    XCTAssertTrue(model.sessions.isEmpty)
    XCTAssertNil(model.message)
  }

  func testUnknownAndOtherUIDCannotUseUnprivilegedStop() async throws {
    for uid: UInt32? in [nil, 502] {
      let active = modelSnapshotJSON(phase: "active", sessions: [
        modelSessionJSON(id: "a", clientName: "CLI", pid: 1, peerUID: 501),
        modelSessionJSON(id: "b", clientName: "CLI", pid: 2, peerUID: uid)], systemSleepDisabled: true)
      let transport = MockDaemonTransport(handshake: DaemonHandshake(
        capabilities: ["session.stopSessions"], snapshot: try DaemonSnapshot(active)), statusValue: active)
      let model = AppModel(transport: transport, currentUID: 501)
      try await model.connectOnce()
      XCTAssertTrue(model.canStopSession(model.sessions[0]))
      XCTAssertFalse(model.canStopSession(model.sessions[1]))
      XCTAssertFalse(model.canStopAll)
      await model.stopSessions(["a", "b"])
      let methods = await transport.requestMethods()
      XCTAssertFalse(methods.contains("session.stopSessions"))
    }
  }

  func testDisplaySleepPreventedUsesConfirmedAggregateInsteadOfOwnOptions() async throws {
    let active = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "cli", clientName: "CLI", pid: 1, keepDisplayOn: true)],
      systemSleepDisabled: true, keepDisplayOn: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(capabilities: [],
      snapshot: try DaemonSnapshot(active)), statusValue: active)
    let model = AppModel(transport: transport)
    XCTAssertNil(model.displaySleepPrevented)
    try await model.connectOnce()
    XCTAssertFalse(model.options.keepDisplayOn)
    XCTAssertEqual(model.displaySleepPrevented, true)
    for state in [
      modelSnapshotJSON(revision: "2", phase: "degraded"),
      modelSnapshotJSON(revision: "3", keepDisplayOn: nil),
      modelSnapshotJSON(revision: "4", keepDisplayOn: true)] {
      await transport.enqueue(.object(["event": .string("status.changed"), "data": .object(["snapshot": state])]))
      try await model.pollOnce()
      XCTAssertNil(model.displaySleepPrevented)
    }
  }
}

@available(macOS 14.0, *)
@MainActor
extension AppModelTests {
  func testLegacyAdminCapabilityKeepsAuthorizationRoute() async throws {
    let active = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "cli", clientName: "CLI", pid: 1)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["admin.stopSessions"], snapshot: try DaemonSnapshot(active)),
      statusValue: modelSnapshotJSON(revision: "5"))
    let model = AppModel(transport: transport,
      authorize: { ManagementCredential(externalForm: "fixture-credential") }, currentUID: 501)
    try await model.connectOnce()
    XCTAssertTrue(model.canStopAll)
    await model.stopSessions(["cli"])
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("admin.stopSessions"))
    XCTAssertFalse(methods.contains("session.stopSessions"))
    XCTAssertTrue(model.sessions.isEmpty)
  }

  func testSameUIDBulkStopClearsOwnedScheduleAfterConfirmedRefresh() async throws {
    let running = modelSnapshotJSON(revision: "3", phase: "active", sessions: [
      modelSessionJSON(id: "own", clientName: "UI", pid: 1, peerUID: 501),
      modelSessionJSON(id: "cli", clientName: "CLI", pid: 2, peerUID: 501)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["session.stopSessions"], snapshot: try DaemonSnapshot(modelSnapshotJSON())), statusValue: running)
    let model = AppModel(transport: transport, currentUID: 501)
    try await model.connectOnce()
    await model.start()
    XCTAssertTrue(model.schedule.running)
    await transport.setStatusValue(modelSnapshotJSON(revision: "5"))
    await model.stopSessions(["own", "cli"])
    XCTAssertNil(model.ownSessionID)
    XCTAssertFalse(model.schedule.running)
    XCTAssertFalse(model.cleanupUnconfirmed)
    XCTAssertTrue(model.canStart)
  }
}

@available(macOS 14.0, *)
@MainActor
extension AppModelTests {
  func testSelectionWithAlreadyEndedSessionStillUsesUnprivilegedStop() async throws {
    let selected = modelSnapshotJSON(phase: "active", sessions: [
      modelSessionJSON(id: "remaining", clientName: "CLI", pid: 1, peerUID: 501),
      modelSessionJSON(id: "ended", clientName: "CLI", pid: 2, peerUID: 501)], systemSleepDisabled: true)
    let transport = MockDaemonTransport(handshake: DaemonHandshake(
      capabilities: ["session.stopSessions", "admin.stopSessions"], snapshot: try DaemonSnapshot(selected)),
      statusValue: modelSnapshotJSON(revision: "5"))
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied }, currentUID: 501)
    try await model.connectOnce()
    let selectedIDs = model.sessions.map(\.id)
    let remaining = modelSnapshotJSON(revision: "2", phase: "active", sessions: [
      modelSessionJSON(id: "remaining", clientName: "CLI", pid: 1, peerUID: 501)], systemSleepDisabled: true)
    await transport.enqueue(.object(["event": .string("status.changed"), "data": .object(["snapshot": remaining])]))
    try await model.pollOnce()
    await model.stopSessions(selectedIDs)
    let methods = await transport.requestMethods()
    XCTAssertTrue(methods.contains("session.stopSessions"))
    XCTAssertFalse(methods.contains("admin.stopSessions"))
    XCTAssertTrue(model.sessions.isEmpty)
    XCTAssertNil(model.message)
  }

  func testMonitoringPollFailureClosesOnceAndReconnects() async throws {
    // One poll failure must not close the transport twice (pollOnce's
    // internal handling plus the monitoring loop's catch), and the stale
    // handling must not close a transport that reconnected afterwards.
    let idle = modelSnapshotJSON()
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied })
    model.startMonitoring()
    for _ in 0..<200 {
      if await transport.connectCount() >= 1 { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(model.connectionState, .connected)
    await transport.setCloseHeld(true)
    await transport.setPollFailure(.disconnected)
    await transport.waitUntilCloseStarted()
    await transport.setPollFailure(nil)

    // Attempt the reconnect while the stale close is still suspended. It
    // must wait for that close instead of creating a connection the close can
    // tear down afterwards.
    let reconnect = Task { @MainActor in try await model.connectOnce() }
    try await Task.sleep(nanoseconds: 100_000_000)
    let connectsWhileClosing = await transport.connectCount()
    XCTAssertEqual(connectsWhileClosing, 1)
    await transport.releaseClose()
    try await reconnect.value
    for _ in 0..<100 {
      if model.connectionState == .connected, await transport.connectCount() >= 2 { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertEqual(model.connectionState, .connected)
    let closes = await transport.closeCount()
    XCTAssertEqual(closes, 1)
    let didShutdown = await model.shutdown()
    XCTAssertTrue(didShutdown)
  }

  func testMonitoringBacksOffWhenPollReturnsEmptyImmediately() async throws {
    let idle = modelSnapshotJSON()
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    await transport.setEmptyPollDelayNanoseconds(nil)
    let model = AppModel(transport: transport, authorize: { throw DopaAuthorizationError.denied })
    model.startMonitoring()

    for _ in 0..<100 {
      if model.connectionState == .connected, await transport.pollCount() > 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let before = await transport.pollCount()
    try await Task.sleep(nanoseconds: 200_000_000)
    let after = await transport.pollCount()
    XCTAssertLessThanOrEqual(after - before, 1, "an immediate empty poll must not busy-loop")
    let didShutdown = await model.shutdown()
    XCTAssertTrue(didShutdown)
  }

  func testBusyDeadlineRetriesWithinPreviousOneSecondCadence() async throws {
    let idle = modelSnapshotJSON()
    let running = modelSnapshotJSON(
      revision: "3", phase: "active",
      sessions: [modelSessionJSON(id: "own", clientName: "Dopa UI", pid: 2187)],
      systemSleepDisabled: true)
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: running)
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    model.editDuration("00:00:01")
    await transport.setStatusGetHeld(true)

    let start = Task { @MainActor in await model.start() }
    await transport.waitUntilStatusGetStarted()
    try await Task.sleep(nanoseconds: 1_200_000_000)
    await transport.releaseStatusGet()
    await start.value
    await transport.setStatusValue(modelSnapshotJSON(revision: "5"))

    let retryStarted = Date()
    for _ in 0..<50 {
      if model.ownSessionID == nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(model.ownSessionID)
    XCTAssertLessThan(
      Date().timeIntervalSince(retryStarted), 1.5,
      "busy expiry must retain the previous one-second retry cadence")
    let didShutdown = await model.shutdown()
    XCTAssertTrue(didShutdown)
  }

  func testShutdownClosesConnectionInstalledAfterPendingCloseStarted() async throws {
    let idle = modelSnapshotJSON()
    let transport = LateInstallingTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)))
    let model = AppModel(transport: transport)

    let connecting = Task { @MainActor in try await model.connectOnce() }
    await transport.waitUntilConnectStarted()
    let shutdownCompletion = CompletionFlag()
    let shutdown = Task { @MainActor in
      let result = await model.shutdown()
      await shutdownCompletion.markComplete()
      return result
    }
    await transport.waitUntilCloseStarted()

    await transport.releaseConnect()
    for _ in 0..<100 {
      if await transport.isConnected() { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let installedAfterClose = await transport.isConnected()
    XCTAssertTrue(installedAfterClose)
    await transport.releaseClose()

    await transport.waitUntilCloseStarted(count: 2)
    try await Task.sleep(nanoseconds: 50_000_000)
    let returnedBeforeFinalClose = await shutdownCompletion.isComplete
    XCTAssertFalse(returnedBeforeFinalClose, "shutdown must await the late handshake's final close")
    await transport.releaseClose()

    let didShutdown = await shutdown.value
    XCTAssertTrue(didShutdown)
    do {
      _ = try await connecting.value
      XCTFail("a handshake completed after shutdown must be rejected")
    } catch is CancellationError {}
    let connectedAfterShutdown = await transport.isConnected()
    let closeCount = await transport.closeCount()
    XCTAssertFalse(connectedAfterShutdown)
    XCTAssertEqual(closeCount, 2)
  }

  func testConcurrentConnectOnceCallsSerializeTransportHandshakes() async throws {
    let idle = modelSnapshotJSON()
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    await transport.setConnectHeld(true)
    let model = AppModel(transport: transport)

    let first = Task { @MainActor in try await model.connectOnce() }
    await transport.waitUntilConnectStarted()
    let second = Task { @MainActor in try await model.connectOnce() }
    try await Task.sleep(nanoseconds: 50_000_000)
    let connectsWhileHeld = await transport.connectCount()
    XCTAssertEqual(connectsWhileHeld, 1)

    await transport.releaseConnect()
    try await first.value
    try await second.value
    XCTAssertEqual(model.connectionState, .connected)
    let totalConnects = await transport.connectCount()
    XCTAssertEqual(totalConnects, 2, "each public call must retain its connection attempt")
    let didShutdown = await model.shutdown()
    XCTAssertTrue(didShutdown)
  }

  func testQueuedConnectFailureDisconnectsConnectionItReplaced() async throws {
    let idle = modelSnapshotJSON()
    let transport = MockDaemonTransport(
      handshake: DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(idle)),
      statusValue: idle)
    await transport.setConnectHeld(true)
    await transport.failConnect(attempt: 2)
    let model = AppModel(transport: transport)

    // Let one public attempt own the permit, then queue a second public attempt
    // behind it while the first handshake is suspended.
    let first = Task { @MainActor in try await model.connectOnce() }
    await transport.waitUntilConnectStarted()
    let second = Task { @MainActor in try await model.connectOnce() }
    try await Task.sleep(nanoseconds: 50_000_000)
    let connectsWhileHeld = await transport.connectCount()
    XCTAssertEqual(connectsWhileHeld, 1)

    await transport.releaseConnect()
    try await first.value
    do {
      try await second.value
      XCTFail("the configured second connection attempt must fail")
    } catch MockDaemonTransport.Failure.disconnected {}
    let totalConnects = await transport.connectCount()
    XCTAssertEqual(totalConnects, 2)
    XCTAssertEqual(
      model.connectionState, .disconnected,
      "the queued attempt's failure must invalidate the connection it replaced")
    XCTAssertNil(model.snapshot)
    let closesAfterFailure = await transport.closeCount()
    XCTAssertEqual(closesAfterFailure, 1)

    let didShutdown = await model.shutdown()
    XCTAssertTrue(didShutdown)
  }
}

private actor CompletionFlag {
  private(set) var isComplete = false
  func markComplete() { isComplete = true }
}
