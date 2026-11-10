import AppKit
import CoreGraphics
import DopaUIModel
import Observation

/// Shows Dopa's screen saver after a period without input while Dopa keeps
/// the display on. A display-sleep assertion also keeps macOS from starting
/// its screen saver, so this restores one as an opt-in.
///
/// It deliberately does not start the macOS screen saver: that one begins the
/// system's "require password after the screen saver begins" countdown and
/// locks the Mac that the user asked Dopa to keep available.
///
/// The controller never polls on a fixed cadence: it sleeps until the
/// earliest moment the idle delay could elapse, and it does nothing while the
/// option is off or no session prevents display sleep.
@available(macOS 14.0, *)
@MainActor
final class IdleScreenSaverController {
  private let model: AppModel
  private let defaults: UserDefaults
  private let presenter = IdleScreenSaverPresenter()
  private var policy: IdleScreenSaverPolicy
  private var task: Task<Void, Never>?
  private var defaultsObserver: NSObjectProtocol?

  init(model: AppModel, defaults: UserDefaults = .standard) {
    self.model = model
    self.defaults = defaults
    policy = IdleScreenSaverPolicy(
      delaySeconds: defaults.integer(forKey: IdleScreenSaverPolicy.defaultsKey))
  }

  func start() {
    guard defaultsObserver == nil else { return }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reloadDelay() }
    }
    observeDisplayState()
    reschedule()
  }

  private func reloadDelay() {
    let seconds = defaults.integer(forKey: IdleScreenSaverPolicy.defaultsKey)
    guard IdleScreenSaverPolicy.normalized(seconds) != policy.delay else { return }
    policy.setDelay(seconds: seconds)
    reschedule()
  }

  private func observeDisplayState() {
    withObservationTracking {
      _ = model.displaySleepPrevented
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.observeDisplayState()
        self?.reschedule()
      }
    }
  }

  private func reschedule() {
    task?.cancel()
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let wait = self?.step() else { return }
        try? await Task.sleep(for: .seconds(max(1, wait)))
      }
    }
  }

  /// Evaluates the policy once and returns how long to wait before the next
  /// check, or `nil` when nothing needs watching.
  private func step() -> TimeInterval? {
    let decision = policy.evaluate(
      now: ProcessInfo.processInfo.systemUptime,
      idle: Self.secondsSinceLastInput(),
      displaySleepPrevented: model.displaySleepPrevented == true)
    switch decision {
    case .inactive:
      // Once the display may sleep again, macOS takes over idle handling.
      presenter.dismiss()
      return nil
    case .wait(let seconds):
      return seconds
    case .launch(let nextCheck):
      if Self.sessionIsInteractive() { presenter.present() }
      return nextCheck
    }
  }

  private static func secondsSinceLastInput() -> TimeInterval {
    // ~0 is kCGAnyInputEventType, which Swift does not import by name.
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }

  /// A locked screen or a session switched away from the console must not
  /// get a screen saver on top of it.
  private static func sessionIsInteractive() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
    return session["kCGSSessionOnConsoleKey"] as? Bool ?? true
  }
}
