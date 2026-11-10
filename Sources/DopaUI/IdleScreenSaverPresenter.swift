import AppKit

/// Dopa's own screen saver: a black window with a dim, slowly moving clock on
/// every display.
///
/// Starting the macOS screen saver also starts the system's "require password
/// after the screen saver begins" countdown, so the Mac ends up locked even
/// though the user asked Dopa to keep it available. These windows belong to
/// Dopa, never involve loginwindow, and go away on the first user input.
@available(macOS 14.0, *)
@MainActor
final class IdleScreenSaverPresenter {
  /// Pointer travel in points that counts as deliberate input. Smaller
  /// movements come from the window appearing under a resting pointer.
  private static let pointerSlack: CGFloat = 4
  /// Events this soon after presenting are caused by presenting itself.
  private static let settleSeconds: TimeInterval = 0.5
  private static let clockInterval: TimeInterval = 30

  private var windows: [IdleScreenSaverWindow] = []
  private var monitors: [Any] = []
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var clockTimer: Timer?
  private var presentedAt: TimeInterval = 0
  private var pointerOrigin: NSPoint = .zero
  private var previousApplication: NSRunningApplication?

  var isPresented: Bool { !windows.isEmpty }
  var presentedWindows: [NSWindow] { windows }

  func present() {
    guard !isPresented else { return }
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }

    let frontmost = NSWorkspace.shared.frontmostApplication
    previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      ? nil : frontmost
    presentedAt = ProcessInfo.processInfo.systemUptime
    pointerOrigin = NSEvent.mouseLocation

    windows = screens.map { IdleScreenSaverWindow(screen: $0) }
    installMonitors()
    installObservers()
    // Key status delivers keyboard input to the local monitor without the
    // Input Monitoring permission a global key monitor would need.
    NSApp.activate()
    for window in windows { window.orderFrontRegardless() }
    windows.first?.makeKey()
    NSCursor.setHiddenUntilMouseMoves(true)

    let timer = Timer(timeInterval: Self.clockInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.advanceClocks() }
    }
    timer.tolerance = Self.clockInterval / 3
    RunLoop.main.add(timer, forMode: .common)
    clockTimer = timer
  }

  func dismiss() {
    guard isPresented else { return }
    clockTimer?.invalidate()
    clockTimer = nil
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
    for (center, observer) in observers { center.removeObserver(observer) }
    observers = []
    for window in windows { window.orderOut(nil) }
    windows = []
    NSCursor.setHiddenUntilMouseMoves(false)
    // Hand focus back so the dismissing input does not leave the user in a
    // menu bar app without windows.
    previousApplication?.activate()
    previousApplication = nil
  }

  private func advanceClocks() {
    for window in windows { window.advanceClock() }
  }

  private func installMonitors() {
    let mask: NSEvent.EventTypeMask = [
      .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    // Swallow the input that wakes the screen, like the system does.
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handleInput(event.type) == true ? nil : event
    }
    if let local { monitors.append(local) }
    // Covers pointer input when another application kept or regained focus.
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      let type = event.type
      MainActor.assumeIsolated { _ = self?.handleInput(type) }
    }
    if let global { monitors.append(global) }
  }

  /// Dismisses on deliberate input. Returns whether the event was consumed.
  private func handleInput(_ type: NSEvent.EventType) -> Bool {
    guard isPresented else { return false }
    let settled = ProcessInfo.processInfo.systemUptime - presentedAt >= Self.settleSeconds
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      let location = NSEvent.mouseLocation
      let travel = hypot(location.x - pointerOrigin.x, location.y - pointerOrigin.y)
      guard settled, travel > Self.pointerSlack else {
        if !settled { pointerOrigin = location }
        return true
      }
    default:
      break
    }
    dismiss()
    return true
  }

  private func installObservers() {
    let dismissing: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
    func observe(_ center: NotificationCenter, _ name: Notification.Name) {
      observers.append(
        (center, center.addObserver(forName: name, object: nil, queue: .main, using: dismissing)))
    }
    // The window layout no longer matches the displays, or the session is no
    // longer the user's to look at.
    observe(.default, NSApplication.didChangeScreenParametersNotification)
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.sessionDidResignActiveNotification)
    observe(workspace, NSWorkspace.screensDidSleepNotification)
    observe(workspace, NSWorkspace.willSleepNotification)
  }
}

@available(macOS 14.0, *)
@MainActor
final class IdleScreenSaverWindow: NSWindow {
  private let clock = NSTextField(labelWithString: "")
  private let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  init(screen: NSScreen) {
    super.init(
      contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    level = .screenSaver
    backgroundColor = .black
    isOpaque = true
    hasShadow = false
    animationBehavior = .none
    acceptsMouseMovedEvents = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    setFrame(screen.frame, display: false)

    clock.font = .monospacedDigitSystemFont(ofSize: 64, weight: .thin)
    clock.textColor = NSColor(white: 1, alpha: 0.35)
    contentView?.addSubview(clock)
    advanceClock()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Refreshes the time and moves it so no pixel shows the same thing for
  /// long.
  func advanceClock() {
    guard let bounds = contentView?.bounds else { return }
    clock.stringValue = formatter.string(from: Date())
    clock.sizeToFit()
    let size = clock.frame.size
    let margin: CGFloat = 40
    let maxX = max(margin, bounds.width - size.width - margin)
    let maxY = max(margin, bounds.height - size.height - margin)
    clock.setFrameOrigin(
      NSPoint(x: CGFloat.random(in: margin...maxX), y: CGFloat.random(in: margin...maxY)))
  }
}
