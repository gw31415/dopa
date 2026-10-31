import XCTest

@testable import DopaUIModel

final class IdleScreenSaverTests: XCTestCase {
  func testOffOrDisplayAllowedToSleepIsInactive() {
    var off = IdleScreenSaverPolicy()
    XCTAssertNil(off.delay)
    XCTAssertEqual(off.evaluate(now: 1000, idle: 5000, displaySleepPrevented: true), .inactive)

    var on = IdleScreenSaverPolicy(delaySeconds: 300)
    XCTAssertEqual(on.evaluate(now: 1000, idle: 5000, displaySleepPrevented: false), .inactive)
  }

  func testWaitsUntilDelayThenLaunchesOnce() {
    var policy = IdleScreenSaverPolicy(delaySeconds: 300)
    XCTAssertEqual(policy.evaluate(now: 1000, idle: 100, displaySleepPrevented: true), .wait(200))
    XCTAssertEqual(
      policy.evaluate(now: 1200, idle: 300, displaySleepPrevented: true), .launch(nextCheck: 300))
    // Still the same idle period (with a little reading jitter): no relaunch.
    XCTAssertEqual(policy.evaluate(now: 1500, idle: 600.5, displaySleepPrevented: true), .wait(300))
  }

  func testInputAfterLaunchRearms() {
    var policy = IdleScreenSaverPolicy(delaySeconds: 60)
    XCTAssertEqual(
      policy.evaluate(now: 100, idle: 60, displaySleepPrevented: true), .launch(nextCheck: 60))
    // The user dismissed the screen saver at 130 and then left again; the
    // next check already sees a full idle delay since that input.
    XCTAssertEqual(
      policy.evaluate(now: 190, idle: 60, displaySleepPrevented: true), .launch(nextCheck: 60))
    XCTAssertEqual(policy.evaluate(now: 200, idle: 5, displaySleepPrevented: true), .wait(55))
  }

  func testChangingDelayOrDisplayStateRearms() {
    var policy = IdleScreenSaverPolicy(delaySeconds: 60)
    XCTAssertEqual(
      policy.evaluate(now: 100, idle: 60, displaySleepPrevented: true), .launch(nextCheck: 60))
    XCTAssertEqual(policy.evaluate(now: 101, idle: 61, displaySleepPrevented: false), .inactive)
    XCTAssertEqual(
      policy.evaluate(now: 102, idle: 62, displaySleepPrevented: true), .launch(nextCheck: 60))

    policy.setDelay(seconds: 30)
    XCTAssertEqual(policy.delay, 30)
    XCTAssertEqual(
      policy.evaluate(now: 103, idle: 63, displaySleepPrevented: true), .launch(nextCheck: 30))
    policy.setDelay(seconds: 0)
    XCTAssertNil(policy.delay)
    XCTAssertEqual(policy.evaluate(now: 104, idle: 64, displaySleepPrevented: true), .inactive)
  }

  func testChoicesStartWithOffAndAreAscending() {
    XCTAssertEqual(IdleScreenSaverPolicy.delayChoices.first, 0)
    XCTAssertEqual(IdleScreenSaverPolicy.delayChoices, IdleScreenSaverPolicy.delayChoices.sorted())
  }
}
