import Foundation
import XCTest

@testable import DopaUIModel

final class ScheduleTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }

  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 14))!
  }

  func testInitialStateAndStoppedEditsApplyImmediately() throws {
    var schedule = Schedule(calendar: calendar)
    XCTAssertFalse(schedule.running)
    XCTAssertNil(schedule.deadline)
    XCTAssertEqual(schedule.config, .duration(seconds: 3600))
    XCTAssertNil(schedule.draft)
    XCTAssertEqual(schedule.rememberedSeconds, 3600)

    schedule.editDuration("00:30:00", now: now)
    XCTAssertEqual(schedule.config, .duration(seconds: 1800))
    XCTAssertNil(schedule.draft)
    schedule.editEnd("14:30:00", now: now)
    XCTAssertEqual(schedule.config, .end(now.addingTimeInterval(1800)))
    try schedule.start(now: now.addingTimeInterval(60))
    XCTAssertEqual(schedule.deadline, now.addingTimeInterval(1800))
  }

  func testStopReturnsToLastAppliedConfigurationAndDiscardsDraft() throws {
    var duration = Schedule(calendar: calendar)
    duration.editDuration("01:20:00", now: now)
    try duration.start(now: now)
    duration.editEndDate(now.addingTimeInterval(1800), now: now)
    duration.stop()
    XCTAssertEqual(duration.basis, .duration)
    XCTAssertEqual(duration.config, .duration(seconds: 4800))
    XCTAssertNil(duration.draft)
    XCTAssertNil(duration.deadline)

    var absolute = Schedule(calendar: calendar)
    let end = now.addingTimeInterval(3600)
    absolute.editEndDate(end, now: now)
    try absolute.start(now: now)
    absolute.editDuration("00:10:00", now: now)
    absolute.stop()
    XCTAssertEqual(absolute.basis, .end)
    XCTAssertEqual(absolute.config, .end(end))
    XCTAssertNil(absolute.draft)
    XCTAssertNil(absolute.deadline)
  }

  func testStoppedEditIntentFreezesEndOrRemainingDurationWithoutRepeatedResets() {
    var schedule = Schedule(calendar: calendar)
    let end = now.addingTimeInterval(3600)
    schedule.beginEditingBasis(.end, now: now)
    XCTAssertEqual(schedule.basis, .end)
    XCTAssertEqual(schedule.config, .end(end))
    schedule.beginEditingBasis(.end, now: now.addingTimeInterval(60))
    XCTAssertEqual(schedule.proposedTarget(now: now.addingTimeInterval(60)), end)

    schedule.beginEditingBasis(.duration, now: now.addingTimeInterval(90.25))
    XCTAssertEqual(schedule.basis, .duration)
    XCTAssertEqual(schedule.config, .duration(seconds: 3510))
    schedule.beginEditingBasis(.duration, now: now.addingTimeInterval(120))
    XCTAssertEqual(schedule.config, .duration(seconds: 3510))
    XCTAssertEqual(schedule.proposedTarget(now: now.addingTimeInterval(120)), now.addingTimeInterval(3630))
    XCTAssertNil(schedule.draft)
  }

  func testRunningDurationEditIntentCapturesRemainingUntilConfirmOrCancel() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    XCTAssertEqual(schedule.basis, .end)
    let original = schedule.deadline
    schedule.beginEditingBasis(.duration, now: now.addingTimeInterval(120))
    XCTAssertEqual(schedule.basis, .duration)
    XCTAssertEqual(schedule.draft?.seconds, 3480)
    XCTAssertEqual(schedule.deadline, original)
    schedule.beginEditingBasis(.duration, now: now.addingTimeInterval(180))
    XCTAssertEqual(schedule.draft?.seconds, 3480)
    schedule.cancel()
    XCTAssertEqual(schedule.basis, .end)
    XCTAssertEqual(schedule.deadline, original)

    schedule.beginEditingBasis(.duration, now: now.addingTimeInterval(240))
    XCTAssertEqual(schedule.draft?.seconds, 3360)
    try schedule.confirm(now: now.addingTimeInterval(300))
    XCTAssertEqual(schedule.basis, .end)
    XCTAssertEqual(schedule.deadline, now.addingTimeInterval(3660))
    XCTAssertEqual(schedule.config, .duration(seconds: 3360))
  }

  func testRunningEndEditIntentFreezesProposedDraftWithoutChangingAppliedDeadline() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    let original = schedule.deadline
    schedule.editDuration("00:30:00", now: now)
    schedule.beginEditingBasis(.end, now: now.addingTimeInterval(60))
    let proposed = now.addingTimeInterval(1860)
    XCTAssertEqual(schedule.basis, .end)
    XCTAssertEqual(schedule.draft?.end, proposed)
    XCTAssertEqual(schedule.deadline, original)
    schedule.beginEditingBasis(.end, now: now.addingTimeInterval(120))
    XCTAssertEqual(schedule.draft?.end, proposed)
    try schedule.confirm(now: now.addingTimeInterval(180))
    XCTAssertEqual(schedule.deadline, proposed)
    schedule.beginEditingBasis(.end, now: now.addingTimeInterval(240))
    XCTAssertNil(schedule.draft)
    XCTAssertEqual(schedule.deadline, proposed)
  }

  func testEditIntentPreservesInvalidAndExpiredDraftsAndEditsSynchronizeBasis() throws {
    var schedule = Schedule(calendar: calendar)
    schedule.editEndDate(now.addingTimeInterval(120), now: now)
    XCTAssertEqual(schedule.basis, .end)
    schedule.editDuration("invalid", now: now)
    XCTAssertEqual(schedule.basis, .duration)
    let invalid = schedule
    schedule.beginEditingBasis(.end, now: now)
    XCTAssertEqual(schedule, invalid)

    schedule.editEnd("14:30:00", now: now)
    XCTAssertEqual(schedule.basis, .end)
    try schedule.start(now: now)
    schedule.editEndDate(now.addingTimeInterval(1), now: now)
    let expired = schedule
    schedule.beginEditingBasis(.duration, now: now.addingTimeInterval(2))
    XCTAssertEqual(schedule, expired)
    XCTAssertEqual(schedule.validation(now: now.addingTimeInterval(2)), .expiredEndTime)
  }

  func testUnlimitedEditIntentAndAdditionsCannotCreateFiniteTargets() throws {
    for running in [false, true] {
      var schedule = Schedule(calendar: calendar)
      if running { try schedule.start(now: now) }
      schedule.setUnlimited(true, now: now)
      if running { try schedule.confirm(now: now) }
      let unlimited = schedule
      schedule.beginEditingBasis(.end, now: now)
      schedule.beginEditingBasis(.duration, now: now.addingTimeInterval(60))
      XCTAssertEqual(schedule, unlimited)
      XCTAssertFalse(schedule.canAddTime(900, now: now))
      XCTAssertFalse(schedule.addTime(900, now: now))
      XCTAssertFalse(schedule.canAddTime(TimeInterval(900), now: now))
      XCTAssertFalse(schedule.addTime(TimeInterval(900), now: now))
      XCTAssertNil(schedule.target(now: now))
      XCTAssertNil(schedule.proposedTarget(now: now))
    }
  }

  func testRunningDurationDraftPreservesDeadlineUntilConfirmation() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    schedule.editDuration("00:30:00", now: now)
    XCTAssertEqual(schedule.deadline, now.addingTimeInterval(3600))
    XCTAssertEqual(schedule.draft?.seconds, 1800)
    try schedule.confirm(now: now.addingTimeInterval(10))
    XCTAssertEqual(schedule.deadline, now.addingTimeInterval(1810))
    XCTAssertEqual(schedule.config, .duration(seconds: 1800))
  }

  func testCancelAndExpirationDiscardDraft() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    schedule.editEnd("16:00:00", now: now)
    schedule.cancel()
    XCTAssertEqual(schedule.target(now: now.addingTimeInterval(10)), now.addingTimeInterval(3600))

    schedule.editDuration("02:00:00", now: now)
    XCTAssertTrue(schedule.tick(now: now.addingTimeInterval(3600)))
    XCTAssertFalse(schedule.running)
    XCTAssertNil(schedule.deadline)
    XCTAssertNil(schedule.draft)
  }

  func testClockOccurrenceAndLabelsUseNextDay() throws {
    let end = try nextOccurrence("13:00:00", now: now, calendar: calendar)
    XCTAssertEqual(end, now.addingTimeInterval(23 * 3600))
    XCTAssertEqual(dayLabel(end, now: now, calendar: calendar), "明日")
    XCTAssertEqual(clockValue(end, calendar: calendar), "13:00:00")
    XCTAssertEqual(dayLabel(now, now: now, calendar: calendar), "今日")
  }

  func testDateSelectionPreservesExactDateWhenAppliedAndStarted() throws {
    var schedule = Schedule(calendar: calendar)
    let selected = now.addingTimeInterval(23 * 3600 + 0.375)
    schedule.editEndDate(selected, now: now)
    XCTAssertEqual(schedule.config, .end(selected))
    XCTAssertEqual(schedule.target(now: now), selected)
    XCTAssertNil(schedule.draft)
    try schedule.start(now: now.addingTimeInterval(60))
    XCTAssertEqual(schedule.deadline, selected)
  }

  func testPastDateSelectionStaysVisibleWithoutRollingForwardOrReplacingConfiguration() throws {
    var schedule = Schedule(calendar: calendar)
    schedule.editDuration("00:30:00", now: now)
    for selected in [now.addingTimeInterval(-3600), now] {
      schedule.editEndDate(selected, now: now)
      XCTAssertEqual(schedule.config, .duration(seconds: 1800))
      XCTAssertEqual(schedule.draft?.end, selected)
      XCTAssertEqual(schedule.draft?.error, .expiredEndTime)
      XCTAssertEqual(schedule.validation(now: now), .expiredEndTime)
      XCTAssertNil(schedule.proposedTarget(now: now))
      XCTAssertThrowsError(try schedule.start(now: now))
      XCTAssertFalse(schedule.running)
    }
  }

  func testDateSelectionEnforcesInclusiveOneSecondThroughTwentyFourHourRange() throws {
    for seconds in [1.0, 86400.0] {
      var schedule = Schedule(calendar: calendar)
      let selected = now.addingTimeInterval(seconds)
      schedule.editEndDate(selected, now: now)
      XCTAssertNil(schedule.draft)
      XCTAssertNil(schedule.validation(now: now))
      try schedule.start(now: now)
      XCTAssertEqual(schedule.deadline, selected)
    }
    for seconds in [0.5, 86400.25, .greatestFiniteMagnitude] {
      var schedule = Schedule(calendar: calendar)
      let selected = now.addingTimeInterval(seconds)
      schedule.editEndDate(selected, now: now)
      XCTAssertEqual(schedule.config, .duration(seconds: 3600))
      XCTAssertEqual(schedule.draft?.end, selected)
      XCTAssertEqual(schedule.draft?.error, .invalidDurationRange)
      XCTAssertThrowsError(try schedule.confirm(now: now))
    }
  }

  func testNonFiniteDateSelectionAndClockPreserveAppliedState() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    let original = schedule.deadline
    for interval in [Double.nan, Double.infinity, -Double.infinity] {
      let selected = Date(timeIntervalSinceReferenceDate: interval)
      schedule.editEndDate(selected, now: now)
      let retained = try XCTUnwrap(schedule.draft?.end?.timeIntervalSinceReferenceDate)
      XCTAssertTrue(interval.isNaN ? retained.isNaN : retained == interval)
      XCTAssertEqual(schedule.draft?.error, .invalidDate)
      XCTAssertEqual(schedule.config, .duration(seconds: 3600))
      XCTAssertEqual(schedule.deadline, original)
    }
    let selected = now.addingTimeInterval(120)
    schedule.editEndDate(selected, now: Date(timeIntervalSinceReferenceDate: .infinity))
    XCTAssertEqual(schedule.draft?.end, selected)
    XCTAssertEqual(schedule.draft?.error, .invalidDate)
    XCTAssertEqual(schedule.deadline, original)
  }

  func testRunningDateSelectionAppliesExactTargetAndCancelPreservesDeadline() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    let original = schedule.deadline
    let selected = now.addingTimeInterval(7200.375)
    schedule.editEndDate(selected, now: now)
    XCTAssertEqual(schedule.draft?.end, selected)
    XCTAssertEqual(schedule.config, .duration(seconds: 3600))
    XCTAssertEqual(schedule.deadline, original)
    schedule.cancel()
    XCTAssertNil(schedule.draft)
    XCTAssertEqual(schedule.deadline, original)

    schedule.editEndDate(selected, now: now)
    try schedule.confirm(now: now.addingTimeInterval(30))
    XCTAssertEqual(schedule.config, .end(selected))
    XCTAssertEqual(schedule.deadline, selected)
    XCTAssertNil(schedule.draft)

    let past = now.addingTimeInterval(-60)
    schedule.editEndDate(past, now: now)
    XCTAssertEqual(schedule.draft?.end, past)
    XCTAssertThrowsError(try schedule.confirm(now: now))
    XCTAssertEqual(schedule.config, .end(selected))
    XCTAssertEqual(schedule.deadline, selected)
    schedule.cancel()
    XCTAssertEqual(schedule.deadline, selected)
  }

  func testDateRangeIsRecheckedBeforeStartAndRunningApply() throws {
    var stopped = Schedule(calendar: calendar)
    stopped.editEndDate(now.addingTimeInterval(86400), now: now)
    let earlierClock = now.addingTimeInterval(-1)
    XCTAssertEqual(stopped.validation(now: earlierClock), .invalidDurationRange)
    XCTAssertThrowsError(try stopped.start(now: earlierClock)) { error in
      XCTAssertEqual(error as? ScheduleError, .invalidDurationRange)
    }
    XCTAssertFalse(stopped.running)

    var running = Schedule(calendar: calendar)
    try running.start(now: now)
    let original = running.deadline
    let selected = now.addingTimeInterval(1)
    running.editEndDate(selected, now: now)
    XCTAssertThrowsError(try running.confirm(now: now.addingTimeInterval(2))) { error in
      XCTAssertEqual(error as? ScheduleError, .expiredEndTime)
    }
    XCTAssertEqual(running.draft?.end, selected)
    XCTAssertEqual(running.deadline, original)

    running.editEndDate(now.addingTimeInterval(86400), now: now)
    XCTAssertThrowsError(try running.confirm(now: earlierClock)) { error in
      XCTAssertEqual(error as? ScheduleError, .invalidDurationRange)
    }
    XCTAssertEqual(running.deadline, original)
  }

  func testExpiredClockDraftDoesNotChangeAppliedState() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    schedule.editEnd("14:00:01", now: now)
    XCTAssertThrowsError(try schedule.confirm(now: now.addingTimeInterval(2))) { error in
      XCTAssertEqual(error as? ScheduleError, .expiredEndTime)
    }
    XCTAssertEqual(schedule.deadline, now.addingTimeInterval(3600))
    XCTAssertNotNil(schedule.draft)
  }

  func testExpiredRunningDeadlineCannotBeRevivedByEditsOrUnlimited() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    let originalDeadline = schedule.deadline
    let expiredNow = now.addingTimeInterval(3601)
    schedule.editDuration("02:00:00", now: now)

    XCTAssertThrowsError(try schedule.confirm(now: expiredNow)) { error in
      XCTAssertEqual(error as? ScheduleError, .expiredEndTime)
    }
    XCTAssertTrue(schedule.running)
    XCTAssertEqual(schedule.deadline, originalDeadline)
    XCTAssertFalse(schedule.canAddTime(900, now: expiredNow))
    XCTAssertFalse(schedule.addTime(900, now: expiredNow))
    schedule.setUnlimited(true, now: expiredNow)
    XCTAssertTrue(schedule.running)
    XCTAssertEqual(schedule.deadline, originalDeadline)
    XCTAssertEqual(schedule.config, .duration(seconds: 3600))

    XCTAssertTrue(schedule.tick(now: expiredNow))
    XCTAssertFalse(schedule.running)
    XCTAssertNil(schedule.draft)
  }

  func testInvalidInputPreservesAppliedConfiguration() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    let originalDeadline = schedule.deadline
    for value in ["", "00:00:00", "00:60:00", "25:00:00", "1 hour"] {
      schedule.editDuration(value, now: now)
      XCTAssertThrowsError(try schedule.confirm(now: now))
      XCTAssertEqual(schedule.deadline, originalDeadline)
    }
    XCTAssertThrowsError(try nextOccurrence("24:00", now: now, calendar: calendar))
    XCTAssertThrowsError(try parseDuration("手動"))
    XCTAssertEqual(try parseDuration("24:00:00"), 86400)
  }

  func testAddTimeAppliesAndAccumulatesForDurationAndEnd() throws {
    var duration = Schedule(calendar: calendar)
    XCTAssertTrue(duration.addTime(900, now: now))
    XCTAssertEqual(duration.config, .duration(seconds: 4500))
    XCTAssertTrue(duration.addTime(1800, now: now))
    XCTAssertEqual(duration.config, .duration(seconds: 6300))

    var running = Schedule(calendar: calendar)
    try running.start(now: now)
    let original = running.deadline!
    XCTAssertTrue(running.addTime(900, now: now))
    XCTAssertEqual(running.deadline, original.addingTimeInterval(900))
    XCTAssertEqual(running.config, .end(original.addingTimeInterval(900)))
    XCTAssertTrue(running.addTime(1800, now: now.addingTimeInterval(120)))
    XCTAssertEqual(running.deadline, original.addingTimeInterval(2700))
  }

  func testAddTimeCombinesValidDraftAndRejectsInvalidOrExpiredSources() throws {
    var running = Schedule(calendar: calendar)
    try running.start(now: now)
    running.editDuration("00:30:00", now: now)
    XCTAssertTrue(running.canAddTime(900, now: now))
    XCTAssertTrue(running.addTime(900, now: now))
    XCTAssertEqual(running.config, .duration(seconds: 2700))
    XCTAssertEqual(running.deadline, now.addingTimeInterval(2700))

    running.stop()
    running.editDuration("壊れた入力", now: now)
    XCTAssertFalse(running.canAddTime(900, now: now))
    XCTAssertFalse(running.addTime(900, now: now))
    XCTAssertEqual(running.config, .duration(seconds: 2700))

    running.cancel()
    try running.start(now: now)
    running.setUnlimited(true, now: now)
    try running.confirm(now: now)
    XCTAssertFalse(running.addTime(900, now: now))
    XCTAssertNil(running.deadline)
    XCTAssertTrue(running.config.isUnlimited)
  }

  func testUnlimitedRestoresRememberedFiniteTime() throws {
    var stopped = Schedule(calendar: calendar)
    stopped.editDuration("00:45:00", now: now)
    stopped.setUnlimited(true, now: now)
    XCTAssertEqual(stopped.rememberedSeconds, 2700)
    stopped.setUnlimited(false, now: now.addingTimeInterval(120))
    XCTAssertEqual(stopped.config, .duration(seconds: 2700))

    var running = Schedule(calendar: calendar)
    try running.start(now: now)
    running.setUnlimited(true, now: now.addingTimeInterval(120))
    try running.confirm(now: now.addingTimeInterval(120))
    XCTAssertEqual(running.rememberedSeconds, 3480)
    XCTAssertNil(running.deadline)
    running.setUnlimited(false, now: now.addingTimeInterval(180))
    try running.confirm(now: now.addingTimeInterval(180))
    XCTAssertEqual(running.config, .duration(seconds: 3480))
    XCTAssertEqual(running.deadline, now.addingTimeInterval(180 + 3480))
    XCTAssertTrue(running.running)
  }

  func testUnlimitedClearsDraftAndPillsLeaveUnlimitedSchedule() throws {
    var stopped = Schedule(calendar: calendar)
    stopped.setUnlimited(true, now: now)
    stopped.editDuration("壊れた入力", now: now)
    stopped.setUnlimited(true, now: now.addingTimeInterval(120))
    XCTAssertNil(stopped.draft)
    XCTAssertTrue(stopped.config.isUnlimited)
    XCTAssertFalse(stopped.addTime(900, now: now))
    XCTAssertTrue(stopped.config.isUnlimited)

    var running = Schedule(calendar: calendar)
    try running.start(now: now)
    running.setUnlimited(true, now: now)
    try running.confirm(now: now)
    XCTAssertFalse(running.addTime(900, now: now))
    XCTAssertTrue(running.config.isUnlimited)
    XCTAssertNil(running.deadline)
  }

  func testRunningUnlimitedProposalPreservesAppliedScheduleUntilApplyOrCancel() throws {
    var schedule = Schedule(calendar: calendar)
    try schedule.start(now: now)
    let original = schedule
    schedule.setUnlimited(true, now: now.addingTimeInterval(120))
    XCTAssertTrue(schedule.proposedIsUnlimited)
    XCTAssertTrue(schedule.draft?.isValid == true)
    XCTAssertFalse(schedule.config.isUnlimited)
    XCTAssertEqual(schedule.deadline, original.deadline)
    XCTAssertEqual(schedule.rememberedSeconds, original.rememberedSeconds)
    XCTAssertNil(schedule.proposedTarget(now: now))
    XCTAssertFalse(schedule.addTime(900, now: now))
    schedule.cancel()
    XCTAssertEqual(schedule, original)
    schedule.setUnlimited(true, now: now.addingTimeInterval(120))
    schedule.setUnlimited(false, now: now.addingTimeInterval(130))
    XCTAssertEqual(schedule, original)
    schedule.setUnlimited(true, now: now.addingTimeInterval(120))
    try schedule.confirm(now: now.addingTimeInterval(150))
    XCTAssertTrue(schedule.config.isUnlimited)
    XCTAssertNil(schedule.deadline)
    XCTAssertEqual(schedule.rememberedSeconds, 3480)
    XCTAssertNil(schedule.draft)
  }

  func testRunningFiniteProposalFromUnlimitedStartsDeadlineOnlyOnApply() throws {
    var schedule = Schedule(calendar: calendar)
    schedule.editDuration("00:45:00", now: now)
    schedule.setUnlimited(true, now: now)
    try schedule.start(now: now)
    let original = schedule
    schedule.setUnlimited(false, now: now)
    XCTAssertFalse(schedule.proposedIsUnlimited)
    XCTAssertTrue(schedule.config.isUnlimited)
    XCTAssertNil(schedule.deadline)
    XCTAssertEqual(schedule.proposedTarget(now: now), now.addingTimeInterval(2700))
    XCTAssertFalse(schedule.addTime(900, now: now))
    schedule.cancel()
    XCTAssertEqual(schedule, original)
    schedule.setUnlimited(false, now: now)
    schedule.setUnlimited(true, now: now)
    XCTAssertEqual(schedule, original)
    schedule.setUnlimited(false, now: now)
    try schedule.confirm(now: now.addingTimeInterval(90))
    XCTAssertEqual(schedule.deadline, now.addingTimeInterval(2790))
    XCTAssertFalse(schedule.config.isUnlimited)
    XCTAssertNil(schedule.draft)
    XCTAssertEqual(schedule.basis, .end)
  }

  func testPendingUnlimitedCannotEvadeOriginalExpiry() throws {
    var schedule = Schedule(calendar: calendar)
    schedule.editDuration("00:00:10", now: now)
    try schedule.start(now: now)
    schedule.setUnlimited(true, now: now.addingTimeInterval(5))
    XCTAssertThrowsError(try schedule.confirm(now: now.addingTimeInterval(10)))
    XCTAssertTrue(schedule.tick(now: now.addingTimeInterval(10)))
    XCTAssertFalse(schedule.running)
    XCTAssertFalse(schedule.config.isUnlimited)
    XCTAssertNil(schedule.draft)
  }

  func testFormattingRoundsUpAndEnforcesDurationRange() throws {
    XCTAssertEqual(formatDuration(0), "00:00:00")
    XCTAssertEqual(formatDuration(1.01), "00:00:02")
    XCTAssertEqual(formatDuration(3600), "01:00:00")
    XCTAssertEqual(try parseDuration("1:02:03"), 3723)
    XCTAssertEqual(try parseDuration("24:00"), 86400)
    XCTAssertThrowsError(try parseDuration("00:00:00"))
    XCTAssertThrowsError(try parseDuration("25:00:00"))
  }
}
