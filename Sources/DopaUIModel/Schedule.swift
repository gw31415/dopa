import Foundation

/// Validation and state transition errors produced by `Schedule`.
public enum ScheduleError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidDurationFormat
  case invalidDurationRange
  case invalidEndTimeFormat
  case invalidEndTimeRange
  case expiredEndTime
  case pendingEdit
  case invalidDate

  public var description: String {
    switch self {
    case .invalidDurationFormat:
      return "時間は「HH:MM:SS」で入力してください。"
    case .invalidDurationRange:
      return "時間は1秒から24時間の範囲で入力してください。"
    case .invalidEndTimeFormat:
      return "終了時刻を入力してください。"
    case .invalidEndTimeRange:
      return "終了時刻を確認してください。"
    case .expiredEndTime:
      return "終了時刻が過ぎています。時刻を選び直してください。"
    case .pendingEdit:
      return "変更を適用してください。"
    case .invalidDate:
      return "現在時刻を確認してください。"
    }
  }
}

/// A finite schedule setting or an unlimited setting.
public struct Schedule: Equatable, Sendable {
  public static let defaultDurationSeconds = 60 * 60
  public static let maxDurationSeconds = 24 * 60 * 60

  public enum Basis: Equatable, Sendable {
    case duration
    case end
  }

  public enum Config: Equatable, Sendable {
    case duration(seconds: Int?)
    case end(Date)

    public var isUnlimited: Bool {
      if case .duration(seconds: nil) = self { return true }
      return false
    }

    public var durationSeconds: Int? {
      guard case .duration(let seconds) = self else { return nil }
      return seconds
    }

    public var endDate: Date? {
      guard case .end(let date) = self else { return nil }
      return date
    }
  }

  /// An alternate name that reads naturally at call sites that refer to a
  /// schedule's applied configuration.
  public typealias Configuration = Config

  public struct Draft: Equatable, Sendable {
    public typealias Kind = Basis

    public let isUnlimited: Bool
    public let kind: Kind
    public let input: String
    public let seconds: Int?
    public let end: Date?
    public let error: ScheduleError?

    public init(
      kind: Kind,
      input: String,
      seconds: Int? = nil,
      end: Date? = nil,
      error: ScheduleError? = nil,
      isUnlimited: Bool = false
    ) {
      self.isUnlimited = isUnlimited
      self.kind = kind
      self.input = input
      self.seconds = seconds
      self.end = end
      self.error = error
    }

    public var isValid: Bool {
      guard error == nil else { return false }
      if isUnlimited { return true }
      switch kind {
      case .duration:
        return seconds != nil
      case .end:
        return end != nil
      }
    }

    public var errorMessage: String? { error?.description }
    public var endDate: Date? { end }
  }

  public private(set) var running: Bool
  public private(set) var deadline: Date?
  public private(set) var config: Config
  public private(set) var draft: Draft?
  public private(set) var rememberedSeconds: Int

  /// The fixed value represented by the current edit, or applied setting.
  public var basis: Basis {
    if let draft { return draft.kind }
    if running { return .end }
    switch config {
    case .duration: return .duration
    case .end: return .end
    }
  }

  /// The mode displayed by the editor, including an unconfirmed running change.
  public var proposedIsUnlimited: Bool { draft?.isUnlimited ?? config.isUnlimited }

  private let calendar: Calendar

  public init(calendar: Calendar = .current) {
    self.calendar = calendar
    self.running = false
    self.deadline = nil
    self.config = .duration(seconds: Self.defaultDurationSeconds)
    self.draft = nil
    self.rememberedSeconds = Self.defaultDurationSeconds
  }

  /// The currently applied target. A nil target means that the schedule is
  /// unlimited; an expired finite target is returned unchanged for display and
  /// validation by the caller.
  public func target(now: Date = Date()) -> Date? {
    guard !config.isUnlimited else { return nil }
    if running { return deadline }
    switch config {
    case .duration(let seconds):
      guard let seconds else { return nil }
      return adding(seconds: seconds, to: now)
    case .end(let date):
      return date
    }
  }

  /// The target represented by the current input. Invalid drafts return nil;
  /// callers can distinguish that case through `draft?.error`.
  public func proposedTarget(now: Date = Date()) -> Date? {
    guard !proposedIsUnlimited else { return nil }
    guard let draft else { return target(now: now) }
    guard draft.error == nil else { return nil }
    switch draft.kind {
    case .duration:
      guard let seconds = draft.seconds else { return nil }
      return adding(seconds: seconds, to: now)
    case .end:
      return draft.end
    }
  }

  /// Returns the error that would prevent the current draft from being
  /// applied at `now`. An absolute clock draft can become expired while it is
  /// waiting for confirmation, so this check is intentionally time-aware.
  public func validation(now: Date = Date()) -> ScheduleError? {
    guard isFinite(now) else { return .invalidDate }
    guard let draft else {
      if !running, case .end(let end) = config { return endDateError(end, now: now) }
      if running, let deadline, deadline <= now { return .expiredEndTime }
      return nil
    }
    if let error = draft.error { return error }
    guard draft.isValid else { return validationError(for: draft.kind) }
    if running, let deadline, deadline <= now { return .expiredEndTime }
    if draft.kind == .end {
      guard let end = draft.end else { return .invalidEndTimeFormat }
      return endDateError(end, now: now)
    }
    return nil
  }

  /// Freezes the displayed value when a user starts changing an input.
  /// While running, editing duration captures the current remaining seconds.
  /// Selection and keyboard navigation alone must not call this method.
  /// Invalid or expired inputs are preserved until edited or cancelled.
  public mutating func beginEditingBasis(_ next: Basis, now: Date = Date()) {
    guard !proposedIsUnlimited, validation(now: now) == nil else { return }
    if next == basis {
      guard running, draft == nil, next == .duration else { return }
    }
    guard let end = proposedTarget(now: now), endDateError(end, now: now) == nil else { return }
    switch next {
    case .end:
      editEndDate(end, now: now)
    case .duration:
      // Match the displayed whole-second remaining duration without shortening
      // it. The range check above bounds this conversion to at most 24 hours.
      let seconds = Int(ceil(end.timeIntervalSince(now)))
      editDuration(_formatDuration(seconds), now: now)
    }
  }

  /// Records a duration input. When stopped, a valid value is applied at once;
  /// while running, the input remains a draft until `confirm(now:)`.
  public mutating func editDuration(_ value: String, now: Date = Date()) {
    _ = now
    do {
      let seconds = try _parseDuration(value)
      let nextDraft = Draft(kind: .duration, input: value, seconds: seconds)
      if running {
        draft = nextDraft
      } else {
        config = .duration(seconds: seconds)
        draft = nil
      }
    } catch let error as ScheduleError {
      draft = Draft(kind: .duration, input: value, error: error)
    } catch {
      draft = Draft(kind: .duration, input: value, error: .invalidDurationFormat)
    }
  }

  /// Records an absolute clock input using the schedule calendar. A clock
  /// value at or before `now` is interpreted as the next day's occurrence.
  public mutating func editEnd(_ value: String, now: Date = Date()) {
    do {
      let end = try _nextOccurrence(value, now: now, calendar: calendar)
      let nextDraft = Draft(kind: .end, input: value, end: end)
      if running {
        draft = nextDraft
      } else {
        config = .end(end)
        draft = nil
      }
    } catch let error as ScheduleError {
      draft = Draft(kind: .end, input: value, error: error)
    } catch {
      draft = Draft(kind: .end, input: value, error: .invalidEndTimeFormat)
    }
  }

  /// Records an exact date selection without interpreting it as a clock value.
  /// Invalid selections remain in the draft for display, while the applied
  /// configuration and any running deadline remain unchanged.
  public mutating func editEndDate(_ value: Date, now: Date = Date()) {
    let error = endDateError(value, now: now)
    let nextDraft = Draft(
      kind: .end, input: error == nil ? _clockValue(value, calendar: calendar) : "",
      end: value, error: error)
    if running || error != nil {
      draft = nextDraft
    } else {
      config = .end(value)
      draft = nil
    }
  }

  /// Applies a running draft, or does nothing when there is no draft.
  public mutating func confirm(now: Date = Date()) throws {
    guard let draft else { return }
    if let error = validation(now: now) { throw error }
    if running, let deadline, deadline <= now { throw ScheduleError.expiredEndTime }

    if draft.isUnlimited {
      if let seconds = draft.seconds { rememberedSeconds = seconds }
      config = .duration(seconds: nil)
      deadline = nil
      self.draft = nil
      return
    }
    switch draft.kind {
    case .duration:
      guard let seconds = draft.seconds,
        let nextDeadline = adding(seconds: seconds, to: now)
      else { throw ScheduleError.invalidDate }

      config = .duration(seconds: seconds)
      if running { deadline = nextDeadline }
      self.draft = nil

    case .end:
      guard let end = draft.end else { throw ScheduleError.invalidEndTimeFormat }
      guard isFinite(end), end > now else { throw ScheduleError.expiredEndTime }

      config = .end(end)
      if running { deadline = end }
      self.draft = nil
    }
  }

  /// Discards an unconfirmed running edit.
  public mutating func cancel() {
    draft = nil
  }

  /// Starts the applied schedule. A pending draft must be confirmed or
  /// cancelled first.
  public mutating func start(now: Date = Date()) throws {
    guard draft == nil else { throw ScheduleError.pendingEdit }
    guard isFinite(now) else { throw ScheduleError.invalidDate }

    let nextDeadline: Date?
    switch config {
    case .duration(let seconds):
      guard let seconds else {
        nextDeadline = nil
        break
      }
      guard let end = adding(seconds: seconds, to: now) else {
        throw ScheduleError.invalidDate
      }
      nextDeadline = end
    case .end(let end):
      if let error = endDateError(end, now: now) { throw error }
      nextDeadline = end
    }

    running = true
    deadline = nextDeadline
  }

  /// Stops the schedule and removes any unconfirmed edit.
  public mutating func stop() {
    running = false
    deadline = nil
    draft = nil
  }

  /// Proposes mode changes while running; stopped changes apply immediately.
  /// Returning to the applied mode discards the unconfirmed change.
  public mutating func setUnlimited(_ enabled: Bool, now: Date = Date()) {
    guard isFinite(now) else { return }
    if running, let deadline, deadline <= now { return }
    if running {
      guard enabled != proposedIsUnlimited else { return }
      if enabled == config.isUnlimited {
        draft = nil
      } else if enabled {
        var snapshot = self
        snapshot.rememberFiniteTarget(now: now)
        draft = Draft(kind: .duration, input: "", seconds: snapshot.rememberedSeconds, isUnlimited: true)
      } else {
        draft = Draft(kind: .duration, input: _formatDuration(rememberedSeconds), seconds: rememberedSeconds)
      }
      return
    }
    if enabled {
      rememberFiniteTarget(now: now)
      draft = nil
      config = .duration(seconds: nil)
    } else if config.isUnlimited {
      draft = nil
      config = .duration(seconds: rememberedSeconds)
    }
  }

  /// Returns whether adding a positive number of seconds can be applied
  /// without exceeding the 24-hour limit or reviving an expired target.
  public func canAddTime(_ seconds: Int, now: Date = Date()) -> Bool {
    addTimePlan(seconds, now: now) != nil
  }

  public func canAddTime(_ seconds: TimeInterval, now: Date = Date()) -> Bool {
    guard seconds.isFinite, seconds.rounded() == seconds,
      seconds > 0, seconds <= TimeInterval(Self.maxDurationSeconds)
    else { return false }
    return canAddTime(Int(seconds), now: now)
  }

  /// Adds time immediately, clearing a valid draft when one is present.
  @discardableResult
  public mutating func addTime(_ seconds: Int, now: Date = Date()) -> Bool {
    guard let plan = addTimePlan(seconds, now: now) else { return false }

    switch plan {
    case .duration(let value):
      config = .duration(seconds: value)
      if running {
        guard let end = adding(seconds: value, to: now) else { return false }
        deadline = end
      }
    case .end(let end):
      config = .end(end)
      if running { deadline = end }
    }
    draft = nil
    return true
  }

  @discardableResult
  public mutating func addTime(_ seconds: TimeInterval, now: Date = Date()) -> Bool {
    guard seconds.isFinite, seconds.rounded() == seconds,
      seconds > 0, seconds <= TimeInterval(Self.maxDurationSeconds)
    else { return false }
    return addTime(Int(seconds), now: now)
  }

  /// Ends a finite schedule when its deadline has passed. This remains usable
  /// while the panel is closed, since it only depends on the caller's clock.
  @discardableResult
  public mutating func tick(now: Date = Date()) -> Bool {
    guard isFinite(now), running, let deadline, deadline <= now else { return false }
    stop()
    return true
  }

  // MARK: - Formatting helpers

  public static func formatDuration(_ seconds: Int) -> String {
    _formatDuration(seconds)
  }

  public static func formatDuration(_ seconds: TimeInterval) -> String {
    _formatDuration(seconds)
  }

  public static func parseDuration(_ text: String) throws -> Int {
    try _parseDuration(text)
  }

  public static func clockValue(_ date: Date, calendar: Calendar = .current) -> String {
    _clockValue(date, calendar: calendar)
  }

  public static func nextOccurrence(
    _ value: String,
    now: Date,
    calendar: Calendar = .current
  ) throws -> Date {
    try _nextOccurrence(value, now: now, calendar: calendar)
  }

  public static func dayLabel(
    _ date: Date?,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    _dayLabel(date, now: now, calendar: calendar)
  }

  // MARK: - Internal state transitions

  private enum AddTimePlan {
    case duration(seconds: Int)
    case end(Date)
  }

  private enum AddTimeSource {
    case duration(seconds: Int)
    case end(Date)
  }

  private func addTimePlan(_ seconds: Int, now: Date) -> AddTimePlan? {
    guard !config.isUnlimited, !proposedIsUnlimited, isFinite(now), seconds > 0,
      seconds <= Self.maxDurationSeconds else { return nil }
    if running, let deadline, deadline <= now { return nil }
    guard let source = addTimeSource() else { return nil }

    switch source {
    case .duration(let base):
      guard base >= 0, base <= Self.maxDurationSeconds else { return nil }
      let sum = base.addingReportingOverflow(seconds)
      guard !sum.overflow, sum.partialValue <= Self.maxDurationSeconds else { return nil }
      let total = sum.partialValue
      return .duration(seconds: total)

    case .end(let end):
      guard isFinite(end), end > now,
        let nextEnd = adding(seconds: seconds, to: end),
        nextEnd > now,
        nextEnd.timeIntervalSince(now) <= TimeInterval(Self.maxDurationSeconds)
      else { return nil }
      return .end(nextEnd)
    }
  }

  private func addTimeSource() -> AddTimeSource? {
    if let draft {
      guard draft.error == nil else { return nil }
      switch draft.kind {
      case .duration:
        guard let seconds = draft.seconds else { return nil }
        return .duration(seconds: seconds)
      case .end:
        guard let end = draft.end else { return nil }
        return .end(end)
      }
    }

    if running {
      return deadline.map(AddTimeSource.end)
    }

    switch config {
    case .duration(let seconds):
      return seconds.map(AddTimeSource.duration)
    case .end(let end):
      return .end(end)
    }
  }

  private mutating func rememberFiniteTarget(now: Date) {
    let candidate = draft?.isValid == true ? proposedTarget(now: now) : target(now: now)
    guard let candidate, isFinite(candidate), candidate > now else { return }
    let interval = candidate.timeIntervalSince(now)
    guard interval.isFinite, interval > 0,
      interval <= Double(Int.max >> 1)
    else { return }
    let seconds = Int(ceil(interval))
    guard (1...Self.maxDurationSeconds).contains(seconds) else { return }
    rememberedSeconds = seconds
  }

  private func adding(seconds: Int, to date: Date) -> Date? {
    guard seconds >= 0, isFinite(date) else { return nil }
    let interval = date.timeIntervalSinceReferenceDate + TimeInterval(seconds)
    guard interval.isFinite else { return nil }
    return Date(timeIntervalSinceReferenceDate: interval)
  }

  private func isFinite(_ date: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.isFinite
  }

  private func endDateError(_ value: Date, now: Date) -> ScheduleError? {
    guard isFinite(value), isFinite(now) else { return .invalidDate }
    guard value > now else { return .expiredEndTime }
    let remaining = value.timeIntervalSince(now)
    guard remaining.isFinite, remaining >= 1,
      remaining <= TimeInterval(Self.maxDurationSeconds)
    else { return .invalidDurationRange }
    return nil
  }

  private func validationError(for kind: Draft.Kind) -> ScheduleError {
    switch kind {
    case .duration: return .invalidDurationFormat
    case .end: return .invalidEndTimeFormat
    }
  }
}

// MARK: - Public formatting functions

/// Formats a duration as HH:MM:SS, rounding fractional seconds upward.
public func formatDuration(_ seconds: TimeInterval) -> String {
  _formatDuration(seconds)
}

private func _formatDuration(_ seconds: TimeInterval) -> String {
  let rounded = seconds.isFinite ? max(0, ceil(seconds)) : 0
  // Keep the conversion below the exact Int range even for a malformed
  // caller-provided floating-point value.
  let bounded = min(rounded, Double(Int.max >> 1))
  return _formatDuration(Int(bounded))
}

public func formatDuration(_ seconds: Int) -> String {
  _formatDuration(seconds)
}

private func _formatDuration(_ seconds: Int) -> String {
  let value = max(0, seconds)
  let hours = value / 3600
  let minutes = value / 60 % 60
  let remainder = value % 60
  return twoDigits(hours) + ":" + twoDigits(minutes) + ":" + twoDigits(remainder)
}

/// Parses HH:MM or HH:MM:SS. Hours may be one or two digits, while minutes
/// and seconds must be two digits. The accepted range is 1 second through 24
/// hours inclusive.
public func parseDuration(_ text: String) throws -> Int {
  try _parseDuration(text)
}

private func _parseDuration(_ text: String) throws -> Int {
  let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  let fields = value.split(separator: ":", omittingEmptySubsequences: false)
  guard fields.count == 2 || fields.count == 3,
    (1...2).contains(fields[0].utf8.count),
    fields[1].utf8.count == 2,
    fields.count == 2 || fields[2].utf8.count == 2,
    let hours = decimal(fields[0]),
    let minutes = decimal(fields[1]),
    let seconds = fields.count == 3 ? decimal(fields[2]) : 0
  else { throw ScheduleError.invalidDurationFormat }

  guard minutes <= 59, seconds <= 59 else {
    throw ScheduleError.invalidDurationRange
  }
  let total = hours * 3600 + minutes * 60 + seconds
  guard total >= 1, total <= Schedule.maxDurationSeconds else {
    throw ScheduleError.invalidDurationRange
  }
  return total
}

/// Returns a local HH:MM:SS value for a date.
public func clockValue(_ date: Date, calendar: Calendar = .current) -> String {
  _clockValue(date, calendar: calendar)
}

private func _clockValue(_ date: Date, calendar: Calendar) -> String {
  guard date.timeIntervalSinceReferenceDate.isFinite else { return "" }
  let components = calendar.dateComponents([.hour, .minute, .second], from: date)
  guard let hour = components.hour, let minute = components.minute, let second = components.second else {
    return ""
  }
  return twoDigits(hour) + ":" + twoDigits(minute) + ":" + twoDigits(second)
}

/// Returns the next local occurrence represented by an HH:MM or HH:MM:SS
/// value. A value at or before `now` is assigned to the following day.
public func nextOccurrence(
  _ value: String,
  now: Date = Date(),
  calendar: Calendar = .current
) throws -> Date {
  try _nextOccurrence(value, now: now, calendar: calendar)
}

private func _nextOccurrence(
  _ value: String,
  now: Date,
  calendar: Calendar
) throws -> Date {
  guard now.timeIntervalSinceReferenceDate.isFinite else { throw ScheduleError.invalidDate }
  let fields = value.split(separator: ":", omittingEmptySubsequences: false)
  guard fields.count == 2 || fields.count == 3,
    fields[0].utf8.count == 2,
    fields[1].utf8.count == 2,
    fields.count == 2 || fields[2].utf8.count == 2,
    let hour = decimal(fields[0]),
    let minute = decimal(fields[1]),
    let second = fields.count == 3 ? decimal(fields[2]) : 0
  else { throw ScheduleError.invalidEndTimeFormat }

  guard hour <= 23, minute <= 59, second <= 59 else {
    throw ScheduleError.invalidEndTimeRange
  }

  var components = calendar.dateComponents([.year, .month, .day], from: now)
  components.hour = hour
  components.minute = minute
  components.second = second
  components.nanosecond = 0
  guard let candidate = calendar.date(from: components) else {
    throw ScheduleError.invalidEndTimeRange
  }
  if candidate <= now {
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate) else {
      throw ScheduleError.invalidEndTimeRange
    }
    return tomorrow
  }
  return candidate
}

/// Returns 今日, 明日, or a compact month/day label for a finite date.
public func dayLabel(
  _ date: Date?,
  now: Date = Date(),
  calendar: Calendar = .current
) -> String {
  _dayLabel(date, now: now, calendar: calendar)
}

private func _dayLabel(
  _ date: Date?,
  now: Date,
  calendar: Calendar
) -> String {
  guard let date, date.timeIntervalSinceReferenceDate.isFinite,
    now.timeIntervalSinceReferenceDate.isFinite
  else { return "" }
  if calendar.isDate(date, inSameDayAs: now) { return "今日" }
  let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
  if let tomorrow, calendar.isDate(date, inSameDayAs: tomorrow) { return "明日" }
  let components = calendar.dateComponents([.month, .day], from: date)
  guard let month = components.month, let day = components.day else { return "" }
  return "\(month)/\(day)"
}

private func decimal(_ value: Substring) -> Int? {
  guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
  return Int(value)
}

private func twoDigits(_ value: Int) -> String {
  let text = String(value)
  guard text.count < 2 else { return text }
  return String(repeating: "0", count: 2 - text.count) + text
}
