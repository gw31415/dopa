import Foundation

/// Decides when the UI should start the macOS screen saver itself.
///
/// While any Dopa session prevents idle display sleep, macOS also stops
/// starting the screen saver on its own. This policy restores that behaviour
/// as an opt-in: after `delay` seconds without user input, the screen saver
/// starts once, and it can start again only after new user input.
///
/// The policy is clock-agnostic. Callers pass a monotonic `now` and the
/// system's seconds since the last user input, so tests need no real clock.
public struct IdleScreenSaverPolicy: Equatable, Sendable {
  /// Selectable delays in seconds, in menu order. `0` means off.
  public static let delayChoices: [Int] = [0, 60, 180, 300, 600, 900, 1800, 3600]
  public static let defaultsKey = "idleScreenSaverDelaySeconds"

  public enum Decision: Equatable, Sendable {
    /// Nothing to watch: the option is off or the display may sleep normally.
    case inactive
    /// Check again after this many seconds.
    case wait(TimeInterval)
    /// Start the screen saver now, then check again after this many seconds.
    case launch(nextCheck: TimeInterval)
  }

  /// Seconds without input before the screen saver starts; `nil` is off.
  public private(set) var delay: TimeInterval?
  /// The time of the last user input that already started the screen saver.
  /// Input after it re-arms the policy.
  private var triggeredInput: TimeInterval?

  public init(delaySeconds: Int = 0) {
    delay = Self.normalized(delaySeconds)
  }

  public static func normalized(_ seconds: Int) -> TimeInterval? {
    seconds > 0 ? TimeInterval(seconds) : nil
  }

  public mutating func setDelay(seconds: Int) {
    let next = Self.normalized(seconds)
    guard next != delay else { return }
    delay = next
    triggeredInput = nil
  }

  /// - Parameters:
  ///   - now: a monotonic timestamp in seconds.
  ///   - idle: seconds since the last user input.
  ///   - displaySleepPrevented: whether Dopa currently keeps the display on.
  public mutating func evaluate(now: TimeInterval, idle: TimeInterval, displaySleepPrevented: Bool)
    -> Decision
  {
    guard let delay, displaySleepPrevented else {
      triggeredInput = nil
      return .inactive
    }
    let idle = max(0, idle)
    if idle < delay { return .wait(delay - idle) }
    // Idle-time readings jitter slightly between calls, so compare the
    // derived input instant with a small tolerance.
    let lastInput = now - idle
    if let triggeredInput, lastInput <= triggeredInput + 1 {
      // Already started for this idle period; the earliest next start is a
      // full delay after the next input.
      return .wait(delay)
    }
    triggeredInput = lastInput
    return .launch(nextCheck: delay)
  }
}
