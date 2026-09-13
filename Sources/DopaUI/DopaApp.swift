import AppKit
import DopaUIModel
import Observation
import SwiftUI

@main
@MainActor
enum DopaEntryPoint {
  static func main() {
    if #available(macOS 26.0, *) { DopaApp.main() }
    else {
      let alert = NSAlert()
      alert.messageText = "Dopa UIにはmacOS 26以降が必要です。"
      alert.runModal()
    }
  }
}

@available(macOS 26.0, *)
@MainActor
struct DopaApp: App {
  @NSApplicationDelegateAdaptor(DopaAppDelegate.self) private var delegate
  @State private var model: AppModel

  init() {
    #if DOPA_UI_TESTING
    // Compiled only into the separate fixture bundle. Production cannot select an untrusted socket.
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--test-socket"), arguments.indices.contains(index + 1) else {
      fatalError("The UI fixture requires --test-socket pointing to a mock-power daemon")
    }
    let model = AppModel(
      transport: SocketTransport(path: arguments[index + 1], requireRoot: false),
      authorize: { ManagementCredential(externalForm: Data(repeating: 0xAB, count: 32).base64EncodedString()) })
    #else
    let model = AppModel()
    #endif
    _model = State(initialValue: model)
    DopaAppDelegate.model = model
    model.startMonitoring()
  }

  var body: some Scene {
    // The status item and its popover are owned by DopaAppDelegate. Suppress
    // the otherwise empty Settings scene when the application launches.
    Settings { EmptyView() }
      .defaultLaunchBehavior(.suppressed)
  }
}

@available(macOS 26.0, *)
@MainActor
final class DopaAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private enum DaemonManagementAction { case install, start }
  private static let daemonConnectionTimeout: Duration = .seconds(10)

  static var model: AppModel?

  private var statusItem: NSStatusItem?
  private var statusActivityIndicator: NSProgressIndicator?
  private var popover: NSPopover?
  var hasPopover: Bool { popover != nil }
  private var popoverInitialFocusView: PopoverInitialFocusView?
  private let daemonInstaller = DaemonInstaller()
  private var daemonManagementPromptActive = false
  private var daemonManagementAlert: NSAlert?
  private var daemonManagementTask: Task<Void, Never>?
  private var terminationRequested = false
  private var terminationTask: Task<Void, Never>?
  private var daemonStartupTransitionActive = false
  private var daemonStartupTransitionTimeoutTask: Task<Void, Never>?
  private var daemonInstalled = false
  private var installationWatcher: ManagedFileWatcher?
  private var quitKeyMonitor: Any?
  private var connectedSinceLaunch = false
  private var offeredStartupRecovery = false
  private lazy var quitMenu: NSMenu = {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = menu.addItem(
      withTitle: "Dopaを終了",
      action: #selector(terminateFromMenu(_:)),
      keyEquivalent: "q"
    )
    item.target = self
    return menu
  }()

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let model = Self.model else { return }
    installApplicationMenu()
    installQuitKeyMonitor()
    daemonInstalled = daemonInstaller.isInstalled
    installStatusItem(for: model)
    observeStatus(of: model)
    beginDaemonInstallationMonitoring()
    connectedSinceLaunch = model.connectionState == .connected
    if daemonUIState == .notInstalled {
      offeredStartupRecovery = true
      DispatchQueue.main.async { [weak self] in
        _ = self?.offerDaemonManagement(.install)
      }
    } else {
      offerStartupRecoveryIfNeeded(for: model)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    guard let model = Self.model else { return .terminateNow }

    terminationRequested = true
    if let alert = daemonManagementAlert {
      if NSApp.modalWindow === alert.window { NSApp.abortModal() }
      alert.window.orderOut(nil)
    }
    let managementTask = daemonManagementTask
    managementTask?.cancel()
    daemonStartupTransitionTimeoutTask?.cancel()
    terminationTask = Task { [weak self] in
      await managementTask?.value
      let canQuit = await model.shutdown()
      guard let self else {
        sender.reply(toApplicationShouldTerminate: canQuit)
        return
      }
      terminationTask = nil
      if !canQuit { terminationRequested = false }
      sender.reply(toApplicationShouldTerminate: canQuit)
    }
    return .terminateLater
  }

  private func installApplicationMenu() {
    let mainMenu = NSMenu()
    mainMenu.autoenablesItems = false
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu(title: "Dopa")
    applicationMenu.autoenablesItems = false
    let quitItem = applicationMenu.addItem(
      withTitle: "Dopaを終了",
      action: #selector(terminateFromMenu(_:)),
      keyEquivalent: "q")
    quitItem.target = self
    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)
    NSApp.mainMenu = mainMenu
  }

  private func installQuitKeyMonitor() {
    guard quitKeyMonitor == nil else { return }
    quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
        event.charactersIgnoringModifiers?.lowercased() == "q"
      else { return event }
      NSApp.terminate(nil)
      return nil
    }
  }

  private func installStatusItem(for model: AppModel) {
    guard statusItem == nil else { return }

    // Keep the status item's width fixed; the popover uses the stable status
    // window content area rather than the image-dependent button bounds.
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = item.button else { return }
    statusItem = item
    button.target = self
    button.action = #selector(statusItemAction(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone

    let activityIndicator = NSProgressIndicator()
    activityIndicator.style = .spinning
    activityIndicator.controlSize = .small
    activityIndicator.isIndeterminate = true
    activityIndicator.isDisplayedWhenStopped = false
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(activityIndicator)
    NSLayoutConstraint.activate([
      activityIndicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      activityIndicator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
    ])
    statusActivityIndicator = activityIndicator

    // The panel popover is built on first presentation (see ensurePopover),
    // not here, so launching the app never pays for views the user may not
    // open. Only construction is deferred: the built popover is kept for the
    // app lifetime, and the model/connection/deadline objects never depend
    // on view lifetime.
    updateStatusItem()
  }

  /// Builds the status popover on first presentation and keeps it. Returning
  /// the same instance preserves draft input, focus, tab order, scroll
  /// position, and error display exactly as if built at launch.
  func ensurePopover(for model: AppModel) -> NSPopover {
    if let popover { return popover }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    let contentController = PanelHostingController(rootView: DopaPanelHost(model: model, clearFocus: { [weak self] in self?.clearTimeFieldFocus() }))
    contentController.prepareSize()

    // A popover becomes key so that an intentional click, Tab, or keyboard
    // shortcut works immediately. Do not let AppKit choose the first editable
    // control as the window's initial responder, though: that would select the
    // duration field (and invoke its focus callback) every time the popover is
    // opened. The zero-sized responder lives in the hosting view and is only a
    // starting point for the key-view loop; it never receives mouse input.
    let initialFocusView = PopoverInitialFocusView(frame: .zero)
    initialFocusView.translatesAutoresizingMaskIntoConstraints = true
    contentController.view.addSubview(initialFocusView)
    popoverInitialFocusView = initialFocusView
    popover.delegate = self
    popover.contentViewController = contentController
    self.popover = popover
    return popover
  }

  private func updateStatusItem() {
    guard let button = statusItem?.button, let model = Self.model else { return }
    let state = daemonUIState
    let status = state.status ?? model.status
    button.title = ""
    if state.showsActivityIndicator {
      button.image = nil
      statusActivityIndicator?.isHidden = false
      statusActivityIndicator?.startAnimation(nil)
    } else {
      statusActivityIndicator?.stopAnimation(nil)
      statusActivityIndicator?.isHidden = true
      button.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: status)
      button.image?.isTemplate = true
    }
    button.toolTip = "Dopa — \(status)"
    button.setAccessibilityLabel("Dopa — \(status)")
  }

  private var daemonUIState: DaemonUIState {
    guard let model = Self.model else { return .checking }
    return .resolve(
      isInstalled: daemonInstalled,
      connectionState: model.connectionState,
      isConfirmed: model.snapshot?.isConfirmed == true,
      hasSessions: !model.sessions.isEmpty,
      isStarting: daemonStartupTransitionActive)
  }

  private func observeStatus(of model: AppModel) {
    withObservationTracking {
      _ = model.status
      _ = model.statusSymbol
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let model = Self.model else { return }
        if model.connectionState == .connected {
          self.connectedSinceLaunch = true
          self.daemonStartupTransitionActive = false
          self.daemonStartupTransitionTimeoutTask?.cancel()
          self.daemonStartupTransitionTimeoutTask = nil
        }
        self.updateStatusItem()
        self.offerStartupRecoveryIfNeeded(for: model)
        self.observeStatus(of: model)
      }
    }
  }

  @objc private func statusItemAction(_ sender: NSStatusBarButton) {
    refreshDaemonInstallationState()
    if NSApp.currentEvent?.type == .rightMouseUp {
      popover?.performClose(nil)
      if let event = NSApp.currentEvent {
        NSMenu.popUpContextMenu(quitMenu, with: event, for: sender)
      } else {
        quitMenu.popUp(
          positioning: nil,
          at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY),
          in: sender
        )
      }
      return
    }

    if let action = daemonManagementActionFromStatusItem {
      popover?.performClose(nil)
      _ = offerDaemonManagement(action)
      return
    }

    guard let button = statusItem?.button, let model = Self.model else { return }
    let popover = ensurePopover(for: model)
    if popover.isShown {
      popover.performClose(sender)
    } else {
      NSApp.activate(ignoringOtherApps: true)
      if let controller = popover.contentViewController as? PanelHostingController<DopaPanelHost> {
        popover.contentSize = controller.prepareSize()
      }
      popover.show(relativeToStatusButton: button)
      if let window = popover.contentViewController?.view.window {
        preparePopoverFocus(in: window)
        window.makeKey()
        if let initialFocusView = popoverInitialFocusView {
          _ = window.makeFirstResponder(initialFocusView)
        }
      }
    }
  }

  private var daemonManagementActionFromStatusItem: DaemonManagementAction? {
    #if DOPA_UI_TESTING
    nil
    #else
    switch daemonUIState.clickAction {
    case .install: .install
    case .start: .start
    case .normal: nil
    }
    #endif
  }

  @discardableResult
  private func offerDaemonManagement(_ action: DaemonManagementAction) -> Bool {
    #if DOPA_UI_TESTING
    return false
    #else
    guard !terminationRequested else { return false }
    switch action {
    case .install:
      guard daemonUIState == .notInstalled else { return false }
    case .start:
      guard daemonUIState == .stopped else { return false }
    }
    guard daemonManagementTask == nil else { return true }
    guard !daemonManagementPromptActive else { return true }
    guard daemonManagementAlert == nil else { return true }

    daemonManagementPromptActive = true
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async { [weak self] in
      self?.presentDaemonManagement(action)
    }
    return true
    #endif
  }

  private func presentDaemonManagement(_ action: DaemonManagementAction) {
    #if !DOPA_UI_TESTING
    guard !terminationRequested else {
      daemonManagementPromptActive = false
      return
    }
    switch action {
    case .install:
      guard daemonUIState == .notInstalled else {
        daemonManagementPromptActive = false
        return
      }
    case .start:
      guard daemonUIState == .stopped else {
        daemonManagementPromptActive = false
        return
      }
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    switch action {
    case .install:
      alert.messageText = "dopa-daemonがインストールされていません"
      alert.informativeText = "Dopaを使用するにはdopa-daemonのインストールが必要です。続けるを選ぶと、管理者認証を求めます。"
    case .start:
      alert.messageText = "dopa-daemonが停止しています"
      alert.informativeText = "Dopaを使用するにはdopa-daemonを起動してください。続けるを選ぶと、管理者認証を求めます。"
    }
    alert.addButton(withTitle: "続ける")
    alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1B}"
    guard runFocusedModal(alert) == .alertFirstButtonReturn else {
      daemonManagementPromptActive = false
      return
    }
    daemonManagementPromptActive = false
    refreshDaemonInstallationState()
    switch action {
    case .install:
      guard daemonUIState == .notInstalled else {
        return
      }
    case .start:
      guard daemonUIState == .stopped else {
        if daemonUIState == .notInstalled { _ = offerDaemonManagement(.install) }
        return
      }
    }

    daemonStartupTransitionActive = true
    updateStatusItem()
    daemonManagementTask = Task { [weak self] in
      guard let self else { return }
      var succeeded = false
      defer {
        if succeeded, !terminationRequested,
          Self.model?.connectionState != .connected {
          beginDaemonStartupTransitionTimeout()
        } else {
          daemonStartupTransitionActive = false
        }
        refreshDaemonInstallationState()
        daemonManagementTask = nil
        updateStatusItem()
      }
      do {
        switch action {
        case .install: try await daemonInstaller.install()
        case .start: try await daemonInstaller.manage(.start)
        }
        succeeded = true
      } catch {
        if !Task.isCancelled, !terminationRequested {
          showDaemonManagementError(error, action: action)
        }
      }
    }
    #endif
  }

  private func beginDaemonStartupTransitionTimeout() {
    guard daemonStartupTransitionTimeoutTask == nil else { return }
    daemonStartupTransitionTimeoutTask = Task { [weak self] in
      do { try await Task.sleep(for: Self.daemonConnectionTimeout) }
      catch { return }
      guard !Task.isCancelled, let self,
        Self.model?.connectionState != .connected else { return }
      daemonStartupTransitionActive = false
      daemonStartupTransitionTimeoutTask = nil
      daemonManagementTask?.cancel()
      updateStatusItem()
      guard !terminationRequested else { return }
      presentDaemonConnectionTimeoutError()
    }
  }

  private func presentDaemonConnectionTimeoutError() {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "dopa-daemonとの接続を確認できませんでした"
    alert.informativeText =
      "dopa-daemonのインストールまたは起動後、10秒以内に接続できませんでした。サービスの状態を確認して再試行してください。"
    _ = runFocusedModal(alert)
  }

  private func beginDaemonInstallationMonitoring() {
    installationWatcher?.stop()
    // vnode events re-verify immediately; the watcher's bounded fallback tick
    // covers missed events. Duplicate file/directory notifications are
    // coalesced before one main-actor refresh, while the previous ~0.5s
    // reflection bound remains intact.
    let watcher = ManagedFileWatcher(files: daemonInstaller.managedFileURLs) {
      [weak self] completed in
      Task { @MainActor [weak self] in
        defer { completed() }
        self?.refreshDaemonInstallationState()
      }
    }
    installationWatcher = watcher
    watcher.start()
    refreshDaemonInstallationState()
  }

  private func refreshDaemonInstallationState() {
    let installed = daemonInstaller.isInstalled
    guard installed != daemonInstalled else { return }
    daemonInstalled = installed
    if !installed {
      daemonStartupTransitionActive = false
      daemonStartupTransitionTimeoutTask?.cancel()
      daemonStartupTransitionTimeoutTask = nil
    } else if daemonStartupTransitionActive,
      Self.model?.connectionState != .connected {
      // During a first install, secure managed files become observable before
      // the privileged helper finishes its readiness check. Start the UI's
      // own bounded connection wait at the same moment the spinner appears.
      beginDaemonStartupTransitionTimeout()
    }
    updateStatusItem()
  }

  private func offerStartupRecoveryIfNeeded(for model: AppModel) {
    guard !offeredStartupRecovery, !connectedSinceLaunch,
      model.connectionState == .disconnected else { return }
    offeredStartupRecovery = true
    switch daemonUIState {
    case .notInstalled: _ = offerDaemonManagement(.install)
    case .stopped: _ = offerDaemonManagement(.start)
    default: break
    }
  }

  private func showDaemonManagementError(
    _ error: Error, action: DaemonManagementAction
  ) {
    guard !terminationRequested else { return }
    presentDaemonManagementError(error, action: action)
  }

  private func presentDaemonManagementError(
    _ error: Error, action: DaemonManagementAction
  ) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    switch action {
    case .install: alert.messageText = "dopa-daemonをインストールできませんでした"
    case .start: alert.messageText = "dopa-daemonを起動できませんでした"
    }
    alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    _ = runFocusedModal(alert)
  }

  private func runFocusedModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
    daemonManagementAlert = alert
    defer {
      if daemonManagementAlert === alert { daemonManagementAlert = nil }
    }
    let window = alert.window
    let button = alert.buttons.first
    window.initialFirstResponder = button
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
      guard window.isVisible else { return }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKey()
      if let button { _ = window.makeFirstResponder(button) }
    }
    return alert.runModal()
  }

  func popoverWillShow(_ notification: Notification) {
    Self.model?.setPresentationActive(true)
    guard let popover = notification.object as? NSPopover,
      let window = popover.contentViewController?.view.window,
      popoverInitialFocusView != nil
    else { return }

    preparePopoverFocus(in: window)
  }

  func popoverDidClose(_ notification: Notification) {
    Self.model?.setPresentationActive(false)
  }

  private func clearTimeFieldFocus() {
    guard let window = popover?.contentViewController?.view.window,
      let initialFocusView = popoverInitialFocusView else { return }
    for case let field as TimeFieldControl in keyViewControls(in: window.contentView, excluding: initialFocusView) {
      field.endEditing(restoreFocus: false)
    }
    _ = window.makeFirstResponder(initialFocusView)
  }

  private func preparePopoverFocus(in window: NSWindow) {
    guard let initialFocusView = popoverInitialFocusView else { return }

    // `initialFirstResponder` is set before NSPopover orders its window key,
    // preventing a transient focus callback from the first duration segment.
    // Reapply it on every presentation because transient popovers retain their
    // content controller across close/reopen cycles.
    window.initialFirstResponder = initialFocusView
    let controls = keyViewControls(in: window.contentView, excluding: initialFocusView)
    initialFocusView.tabTarget = controls.first
    initialFocusView.backtabTarget = controls.last
    _ = window.makeFirstResponder(initialFocusView)
  }

  private func keyViewControls(in view: NSView?, excluding excluded: NSView) -> [NSView] {
    guard let view, view !== excluded, !view.isHidden, view.alphaValue > 0,
      (view as? NSControl)?.isEnabled != false else { return [] }
    // Native time fields each own one tab stop. Never inspect their editors.
    if view is TimeFieldControl || view is NSControl {
      return view.canBecomeKeyView ? [view] : []
    }
    return view.subviews.flatMap { keyViewControls(in: $0, excluding: excluded) }
  }

  @objc private func terminateFromMenu(_ sender: NSMenuItem) {
    NSApplication.shared.terminate(nil)
  }
}

/// A key-view entry point that keeps opening the popover from selecting an
/// editable field. Deliberate Tab and Shift-Tab still enter the normal AppKit
/// key-view loop from this responder.
@available(macOS 26.0, *)
final class PopoverInitialFocusView: NSView {
  var tabTarget: NSView?
  var backtabTarget: NSView?

  override var acceptsFirstResponder: Bool { true }
  // This is an explicit initial responder only. Keeping it out of the key-view
  // loop prevents an invisible stop from appearing when the user tabs through
  // the actual controls.
  override var canBecomeKeyView: Bool { false }

  override func keyDown(with event: NSEvent) {
    guard event.keyCode == 48 else {
      super.keyDown(with: event)
      return
    }
    let selector: Selector = event.modifierFlags.contains(.shift)
      ? #selector(NSResponder.insertBacktab(_:))
      : #selector(NSResponder.insertTab(_:))
    doCommand(by: selector)
  }

  override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(NSResponder.insertTab(_:)):
      if let tabTarget { _ = window?.makeFirstResponder(tabTarget) }
      else { window?.selectKeyView(following: self) }
    case #selector(NSResponder.insertBacktab(_:)):
      if let backtabTarget { _ = window?.makeFirstResponder(backtabTarget) }
      else { window?.selectKeyView(preceding: self) }
    default:
      super.doCommand(by: selector)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
@MainActor
private struct DopaPanelHost: View {
  let model: AppModel
  var clearFocus: () -> Void
  @State private var selectedTab = 0

  var body: some View {
    DopaPanel(model: model, selection: $selectedTab)
      .environment(\.clearTimeFieldFocus, clearFocus)
  }
}
