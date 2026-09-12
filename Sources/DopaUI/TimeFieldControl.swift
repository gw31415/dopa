import AppKit

/// A single tab stop whose embedded editor is entered with Enter or a click.
/// Owns the full field decoration and focus ring; subclasses handle numeric navigation.
@available(macOS 26.0, *)
class TimeFieldControl: NSView {
  var editorView: NSView? { nil }
  var symbolName = "timer" {
    didSet { needsDisplay = true }
  }
  var onEditingChanged: (Bool) -> Void = { _ in }

  var isEnabled = true {
    didSet {
      if !isEnabled && isEditing { endEditing(restoreFocus: false) }
      needsDisplay = true
    }
  }
  var onFocus: () -> Void = {}
  private(set) var isEditing = false

  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

  override func becomeFirstResponder() -> Bool {
    guard isEnabled, super.becomeFirstResponder() else { return false }
    if isEditing { endEditing(restoreFocus: false) }
    onFocus()
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return super.resignFirstResponder()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return isEditing ? hit : self
  }

  override func mouseDown(with event: NSEvent) {
    if isEnabled { _ = startEditing(with: event) }
  }

  override func keyDown(with event: NSEvent) {
    interpretKeyEvents([event])
  }

  override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      _ = startEditing()
    case #selector(NSResponder.insertTab(_:)):
      window?.selectKeyView(following: self)
    case #selector(NSResponder.insertBacktab(_:)):
      window?.selectKeyView(preceding: self)
    default:
      super.doCommand(by: selector)
    }
  }

  func beginFieldEditing() -> Bool { false }
  func beginFieldEditingFromMouse(with event: NSEvent) -> Bool { beginFieldEditing() }
  func finishFieldEditing() {}

  @discardableResult
  func startEditing(with event: NSEvent? = nil) -> Bool {
    guard isEnabled else { return false }
    guard !isEditing else { return true }
    isEditing = true
    let started = if let event { beginFieldEditingFromMouse(with: event) } else { beginFieldEditing() }
    guard started else {
      isEditing = false
      return false
    }
    onEditingChanged(true)
    needsDisplay = true
    return true
  }

  func endEditing(restoreFocus: Bool = true) {
    guard isEditing else { return }
    // Clear first so callbacks and responder changes cannot finish recursively.
    isEditing = false
    finishFieldEditing()
    onEditingChanged(false)
    if restoreFocus && isEnabled { window?.makeFirstResponder(self) }
    needsDisplay = true
  }

  /// Native end-edit notifications can precede the replacement responder.
  /// Reconcile after that transition without taking focus from its destination.
  func editorDidResign() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isEditing else { return }
      @MainActor func containsResponder(_ view: NSView, _ responder: NSResponder) -> Bool {
        if responder === view { return true }
        if let field = view as? NSTextField, responder === field.currentEditor() { return true }
        return view.subviews.contains { containsResponder($0, responder) }
      }
      guard let responder = self.window?.firstResponder,
        self.subviews.contains(where: { containsResponder($0, responder) }) else {
        self.endEditing(restoreFocus: false)
        return
      }
    }
  }

  /// Called by a child editor before its own navigation command handling.
  @discardableResult
  func handleEditingCommand(_ selector: Selector) -> Bool {
    guard isEditing else { return false }
    switch selector {
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
      endEditing()
    case #selector(NSResponder.insertTab(_:)):
      endEditing(restoreFocus: false)
      window?.selectKeyView(following: self)
    case #selector(NSResponder.insertBacktab(_:)):
      endEditing(restoreFocus: false)
      window?.selectKeyView(preceding: self)
    default:
      return false
    }
    return true
  }

  private var editorAlignmentSize: NSSize {
    guard let editorView else { return .zero }
    return editorView.alignmentRect(forFrame: NSRect(origin: .zero, size: editorView.intrinsicContentSize)).size
  }

  override var intrinsicContentSize: NSSize {
    let size = editorAlignmentSize
    return NSSize(width: size.width + 44, height: max(24, size.height + 8))
  }

  override func layout() {
    super.layout()
    guard let editorView else { return }
    let size = editorAlignmentSize
    let alignment = NSRect(x: bounds.maxX - 10 - size.width,
      y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    editorView.frame = editorView.frame(forAlignmentRect: alignment)
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if editorView != nil {
      NSColor.textBackgroundColor.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
      NSColor.separatorColor.setStroke()
      let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
      border.lineWidth = 1
      border.stroke()
      let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [isEnabled ? .labelColor : .disabledControlTextColor]))
      image?.draw(in: NSRect(x: 10, y: bounds.midY - 8, width: 16, height: 16),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    guard isEnabled, isEditing || window?.firstResponder === self else { return }
    NSGraphicsContext.saveGraphicsState()
    NSFocusRingPlacement.only.set()
    drawFocusRingMask()
    NSGraphicsContext.restoreGraphicsState()
  }
}
