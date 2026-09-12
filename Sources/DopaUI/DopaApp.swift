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
      alert.messageText = "dopa UIにはmacOS 26以降が必要です。"
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
    // The status item and its popover are owned by DopaAppDelegate. A
    // Settings scene keeps SwiftUI's App lifecycle without creating a second
    // window or a MenuBarExtra that would consume both mouse buttons.
    Settings { EmptyView() }
  }
}

@available(macOS 26.0, *)
@MainActor
final class DopaAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  static var model: AppModel?

  private var statusItem: NSStatusItem?
  private var popover: NSPopover?
  private var popoverInitialFocusView: PopoverInitialFocusView?
  private lazy var quitMenu: NSMenu = {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = menu.addItem(
      withTitle: "dopaを終了",
      action: #selector(terminateFromMenu(_:)),
      keyEquivalent: "q"
    )
    item.target = self
    return menu
  }()

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let model = Self.model else { return }
    installStatusItem(for: model)
    observeStatus(of: model)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = Self.model else { return .terminateNow }
    Task {
      let canQuit = await model.shutdown()
      sender.reply(toApplicationShouldTerminate: canQuit)
    }
    return .terminateLater
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

    updateStatusItem()
  }

  private func updateStatusItem() {
    guard let button = statusItem?.button, let model = Self.model else { return }
    button.title = ""
    button.image = NSImage(systemSymbolName: model.statusSymbol, accessibilityDescription: model.status)
    button.image?.isTemplate = true
    button.toolTip = "dopa — \(model.status)"
    button.setAccessibilityLabel("dopa — \(model.status)")
  }

  private func observeStatus(of model: AppModel) {
    withObservationTracking {
      _ = model.status
      _ = model.statusSymbol
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let model = Self.model else { return }
        self.updateStatusItem()
        self.observeStatus(of: model)
      }
    }
  }

  @objc private func statusItemAction(_ sender: NSStatusBarButton) {
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

    guard let popover, let button = statusItem?.button else { return }
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

  func popoverWillShow(_ notification: Notification) {
    guard let popover = notification.object as? NSPopover,
      let window = popover.contentViewController?.view.window,
      popoverInitialFocusView != nil
    else { return }

    preparePopoverFocus(in: window)
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
