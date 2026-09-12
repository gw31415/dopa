import AppKit
import SwiftUI

/// A compact duration editor made from three ordinary AppKit text fields.
///
/// The fields intentionally remain native `NSTextField` controls. This keeps
/// selection, text insertion, and accessibility in the system editing stack
/// while the containing view supplies the duration-specific navigation.
@available(macOS 26.0, *)
struct NativeDurationField: NSViewRepresentable {
  @Binding var text: String
  var accessibilityLabel: String
  var onFocus: () -> Void = {}
  var onEdit: () -> Void = {}
  var onEditingChanged: (Bool) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> DurationFieldControl {
    let control = DurationFieldControl()
    let view = control.input
    control.onFocus = { [weak coordinator = context.coordinator] in
      coordinator?.parent.onFocus()
    }
    view.onEdit = { [weak coordinator = context.coordinator] in
      coordinator?.parent.onEdit()
    }
    control.onEditingChanged = { [weak coordinator = context.coordinator] value in
      coordinator?.parent.onEditingChanged(value)
    }
    view.onTextChange = { [weak coordinator = context.coordinator] value in
      coordinator?.parent.text = value
    }
    view.update(
      text: text,
      isEnabled: context.environment.isEnabled,
      accessibilityLabel: accessibilityLabel
    )
    control.isEnabled = view.inputEnabled
    return control
  }

  func updateNSView(_ control: DurationFieldControl, context: Context) {
    context.coordinator.parent = self
    let view = control.input
    view.update(
      text: text,
      isEnabled: context.environment.isEnabled,
      accessibilityLabel: accessibilityLabel
    )
    control.isEnabled = view.inputEnabled
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: DurationFieldControl,
    context: Context
  ) -> CGSize? {
    let intrinsicSize = nsView.intrinsicContentSize
    return CGSize(width: proposal.width ?? intrinsicSize.width, height: intrinsicSize.height)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: NativeDurationField

    init(_ parent: NativeDurationField) {
      self.parent = parent
    }
  }
}

/// The field owns navigation; its text fields only edit duration components.
@available(macOS 26.0, *)
final class DurationFieldControl: TimeFieldControl {
  let input = DurationInputView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(input)
    input.onCommand = { [weak self] in self?.handleEditingCommand($0) ?? false }
    input.onResign = { [weak self] in self?.editorDidResign() }
    setAccessibilityLabel("継続時間、Enterで編集")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override var editorView: NSView? { input }
  override func beginFieldEditing() -> Bool {
    // Keyboard entry always starts at the hours component, even if a prior
    // click left another segment as the last active one.
    input.focusSegment(0)
  }
  override func beginFieldEditingFromMouse(with event: NSEvent) -> Bool {
    guard let window else { return beginFieldEditing() }
    let point = input.convert(event.locationInWindow, from: nil)
    guard let segment = input.segment(at: point) else { return beginFieldEditing() }
    guard input.focusSegment(segment.index) else { return false }

    // TimeFieldControl turns an inactive click into a click on the composite
    // field. Focusing the selected native segment here preserves the native
    // segment selection without re-entering NSTextField's mouse tracking loop
    // while the composite is still handling the original mouse-down event.
    return window.firstResponder === segment || window.firstResponder === segment.currentEditor()
  }
  override func finishFieldEditing() { input.finishEditing() }
}

/// The concrete AppKit view is internal so UI tests can inspect and exercise
/// the native fields without relying on SwiftUI's view tree implementation.
@available(macOS 26.0, *)
final class DurationInputView: NSView, NSTextFieldDelegate {
  private static let componentCount = 3
  private static let maximumHours = 24
  private static let maximumMinutesAndSeconds = 59
  private static let maximumSeconds = 24 * 60 * 60

  /// The three editable controls, in hours, minutes, seconds order.
  /// Keeping this internal also makes focused AppKit tests straightforward.
  var segmentFields: [DurationSegmentField] { fields }

  var onFocus: () -> Void = {}
  var onEdit: () -> Void = {}
  var onCommand: (Selector) -> Bool = { _ in false }
  var onResign: () -> Void = {}
  var onTextChange: (String) -> Void = { _ in }

  private let fields: [DurationSegmentField]
  private let separators: [NSTextField]
  private let stackView: NSStackView
  private var activeIndex: Int?
  private var componentFocused = false
  private var isEditingValue = false
  private var transitionTarget: DurationSegmentField?
  private var isApplyingValue = false
  private var lastPublishedText: String?
  private var deferredExternalText: String?
  private(set) var inputEnabled = false
  private var durationAccessibilityLabel = "継続時間"

  override var acceptsFirstResponder: Bool { inputEnabled }
  override var canBecomeKeyView: Bool { false }

  override init(frame frameRect: NSRect) {
    var createdFields: [DurationSegmentField] = []
    var createdSeparators: [NSTextField] = []
    for index in 0..<Self.componentCount {
      createdFields.append(DurationSegmentField(frame: .zero, index: index))
      if index < Self.componentCount - 1 {
        createdSeparators.append(Self.makeSeparator())
      }
    }
    fields = createdFields
    separators = createdSeparators
    stackView = NSStackView(frame: .zero)
    super.init(frame: frameRect)
    configure()
  }

  required init?(coder: NSCoder) {
    var createdFields: [DurationSegmentField] = []
    var createdSeparators: [NSTextField] = []
    for index in 0..<Self.componentCount {
      createdFields.append(DurationSegmentField(frame: .zero, index: index))
      if index < Self.componentCount - 1 {
        createdSeparators.append(Self.makeSeparator())
      }
    }
    fields = createdFields
    separators = createdSeparators
    stackView = NSStackView(frame: .zero)
    super.init(coder: coder)
    configure()
  }

  override func becomeFirstResponder() -> Bool {
    let index = activeIndex ?? 0
    guard inputEnabled else { return false }
    return fields[index].becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    guard let index = activeIndex else { return super.resignFirstResponder() }
    return fields[index].resignFirstResponder()
  }

  override var intrinsicContentSize: NSSize {
    let width = fields.reduce(CGFloat.zero) { $0 + Self.segmentWidth(for: $1.font) }
      + separators.reduce(CGFloat.zero) { $0 + Self.separatorWidth(for: $1.font) }
    return NSSize(width: ceil(width), height: 16)
  }

  /// Applies a SwiftUI value and enabled state without disturbing a live edit.
  ///
  /// SwiftUI may call this method on every timer tick. A focused segment keeps
  /// its local text and selection while an external value is remembered for a
  /// later, natural refresh after editing ends. An empty value is special: it
  /// always means unlimited and must clear and disable every segment.
  func update(text newText: String, isEnabled: Bool, accessibilityLabel: String) {
    durationAccessibilityLabel = accessibilityLabel
    updateAccessibilityLabels()

    // A SwiftUI update can be the first callback after a key-view transition;
    // reconcile stale local focus state before deciding whether this value is
    // an external tick that should be deferred.
    if componentFocused, transitionTarget == nil, !hasFirstResponderInComponent {
      endFocusSession()
    }

    let shouldEnable = isEnabled && !newText.isEmpty
    inputEnabled = shouldEnable

    if newText.isEmpty {
      deferredExternalText = nil
      lastPublishedText = ""
      componentFocused = false
      isEditingValue = false
      activeIndex = nil
      setAllSegments(["", "", ""], publish: false, selectActive: false)
      fields.forEach { $0.isEnabled = false }
      separators.forEach { $0.stringValue = "" }
      return
    }

    fields.forEach { $0.isEnabled = shouldEnable }
    separators.forEach { $0.stringValue = ":" }
    if componentFocused && isEditingValue {
      deferredExternalText = newText == lastPublishedText ? nil : newText
      return
    }

    deferredExternalText = nil
    let values = Self.segments(for: newText)
    setAllSegments(values, publish: false, selectActive: componentFocused)
    lastPublishedText = newText
  }

  // MARK: - Setup

  private func configure() {
    wantsLayer = false
    setAccessibilityRole(.group)
    stackView.orientation = .horizontal
    stackView.alignment = .centerY
    stackView.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: 16),
    ])

    for index in 0..<Self.componentCount {
      let field = fields[index]
      field.owner = self
      field.delegate = self
      field.font = .systemFont(ofSize: NSFont.systemFontSize)
      field.alignment = .right
      field.isEditable = true
      field.isSelectable = true
      field.isBezeled = false
      field.isBordered = false
      field.drawsBackground = false
      field.focusRingType = .none
      field.usesSingleLineMode = true
      field.maximumNumberOfLines = 1
      field.lineBreakMode = .byClipping
      field.setContentHuggingPriority(.required, for: .horizontal)
      field.setContentCompressionResistancePriority(.required, for: .horizontal)
      field.widthAnchor.constraint(equalToConstant: Self.segmentWidth(for: field.font)).isActive = true
      field.heightAnchor.constraint(equalToConstant: 16).isActive = true
      field.setAccessibilityIdentifier(Self.identifier(for: index))
      stackView.addArrangedSubview(field)
      if index < separators.count {
        let separator = separators[index]
        separator.font = field.font
        separator.alignment = .center
        separator.isEditable = false
        separator.isSelectable = false
        separator.isBezeled = false
        separator.isBordered = false
        separator.drawsBackground = false
        separator.widthAnchor.constraint(equalToConstant: Self.separatorWidth(for: separator.font)).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        separator.setContentHuggingPriority(.defaultLow, for: .horizontal)
        separator.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        separator.setAccessibilityHidden(true)
        stackView.addArrangedSubview(separator)
      }
    }

    for index in 0..<(fields.count - 1) {
      fields[index].nextKeyView = fields[index + 1]
    }
    fields.last?.nextKeyView = self.nextKeyView
    inputEnabled = false
    fields.forEach { $0.isEnabled = false }
    updateAccessibilityLabels()
    invalidateIntrinsicContentSize()
  }

  private static func makeSeparator() -> NSTextField {
    DurationSeparatorField(labelWithString: ":")
  }

  private static func segmentWidth(for font: NSFont?) -> CGFloat {
    let actualFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
    let width = ["00", "88"].map {
      ($0 as NSString).size(withAttributes: [.font: actualFont]).width
    }.max() ?? 0
    // Auto Layout uses the field's alignment rectangle; AppKit supplies the
    // outer editing insets itself, so do not count them a second time.
    return ceil(width)
  }

  private static func separatorWidth(for font: NSFont?) -> CGFloat {
    let actualFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
    let label = NSTextField(labelWithString: ":")
    label.font = actualFont
    // Keep the separator at its native glyph width. The extra inset made the
    // duration control's colons visibly looser than the adjacent NSDatePicker.
    return ceil(label.intrinsicContentSize.width)
  }

  private static func identifier(for index: Int) -> String {
    switch index {
    case 0: return "duration-hours"
    case 1: return "duration-minutes"
    default: return "duration-seconds"
    }
  }

  private func updateAccessibilityLabels() {
    let units = ["時間", "分", "秒"]
    setAccessibilityLabel(durationAccessibilityLabel)
    for (field, unit) in zip(fields, units) {
      field.setAccessibilityLabel("\(durationAccessibilityLabel)、\(unit)")
      field.setAccessibilityValue(field.stringValue)
    }
  }

  // MARK: - Focus and navigation

  fileprivate func willFocus(_ field: DurationSegmentField) {
    guard inputEnabled, let index = fields.firstIndex(where: { $0 === field }) else { return }
    activeIndex = index
    if !componentFocused {
      componentFocused = true
      onFocus()
    }
  }

  fileprivate func didFocus(_ field: DurationSegmentField) {
    guard let index = fields.firstIndex(where: { $0 === field }) else { return }
    activeIndex = index
    selectEntireSegment(index)
  }

  fileprivate func didResign(_ field: DurationSegmentField) {
    guard let index = fields.firstIndex(where: { $0 === field }) else { return }
    if inputEnabled { normalizeSegment(index) }

    // AppKit can report the old field's end edit before installing the
    // replacement field. `transitionTarget` keeps that path in the same focus
    // session; a real outside-field blur can be committed immediately.
    guard transitionTarget == nil, !hasFirstResponderInComponent else { return }
    endFocusSession()
  }

  private func endFocusSession() {
    componentFocused = false
    isEditingValue = false
    // NSDatePicker keeps the selected component when keyboard focus returns.
    guard let deferredExternalText else { return }
    self.deferredExternalText = nil
    setAllSegments(Self.segments(for: deferredExternalText), publish: false, selectActive: false)
    lastPublishedText = deferredExternalText
  }

  private var hasFirstResponderInComponent: Bool {
    guard let firstResponder = window?.firstResponder else { return false }
    return fields.contains { field in
      firstResponder === field || firstResponder === field.currentEditor()
    }
  }

  private func selectEntireSegment(_ index: Int) {
    guard fields.indices.contains(index), let editor = fields[index].currentEditor() else { return }
    editor.selectedRange = NSRange(location: 0, length: fields[index].stringValue.utf16.count)
  }

  private func moveFocus(from index: Int, direction: Int) {
    normalizeSegment(index)
    let target = index + direction
    guard fields.indices.contains(target) else { return }
    focusSegment(target)
  }

  @discardableResult
  func focusSegment(_ index: Int) -> Bool {
    guard fields.indices.contains(index), inputEnabled else { return false }
    activeIndex = index
    transitionTarget = fields[index]
    defer { transitionTarget = nil }
    let accepted: Bool
    if let window {
      accepted = window.makeFirstResponder(fields[index])
    } else {
      accepted = fields[index].becomeFirstResponder()
    }
    selectEntireSegment(index)
    return accepted
  }

  func segment(at point: NSPoint) -> DurationSegmentField? {
    let stackPoint = stackView.convert(point, from: self)
    return fields.first { $0.frame.contains(stackPoint) }
  }

  func finishEditing() {
    if inputEnabled { normalizeAllSegments() }
  }

  // MARK: - NSTextFieldDelegate

  func controlTextDidBeginEditing(_ notification: Notification) {
    guard let field = notification.object as? DurationSegmentField else { return }
    willFocus(field)
    didFocus(field)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard !isApplyingValue, let field = notification.object as? DurationSegmentField,
      let index = fields.firstIndex(where: { $0 === field })
    else { return }
    handleChangedText(in: index)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? DurationSegmentField else { return }
    didResign(field)
    onResign()
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard let field = control as? DurationSegmentField,
      let index = fields.firstIndex(where: { $0 === field })
    else { return false }

    switch commandSelector {
    case #selector(NSResponder.insertTab(_:)):
      if index < fields.count - 1 {
        normalizeSegment(index)
        _ = focusSegment(index + 1)
        return true
      }
    case #selector(NSResponder.insertBacktab(_:)):
      if index > 0 {
        normalizeSegment(index)
        _ = focusSegment(index - 1)
        return true
      }
    default:
      break
    }

    // Only a boundary Tab/Backtab is delegated to the enclosing control. This
    // lets the shared field navigation leave the complete duration input in a
    // single step after the user traverses all three segments.
    if onCommand(commandSelector) { return true }
    switch commandSelector {
    case #selector(NSResponder.moveLeft(_:)):
      moveFocus(from: index, direction: -1)
      return true
    case #selector(NSResponder.moveRight(_:)):
      moveFocus(from: index, direction: 1)
      return true
    case #selector(NSResponder.moveUp(_:)):
      adjustDuration(from: index, direction: 1)
      return true
    case #selector(NSResponder.moveDown(_:)):
      adjustDuration(from: index, direction: -1)
      return true
    default:
      return false
    }
  }

  // MARK: - Editing

  private func handleChangedText(in index: Int) {
    let field = fields[index]
    let raw = field.stringValue
    let digits = String(raw.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
    let accepted: String
    if digits.count == 2,
      let value = Int(digits), value > Self.maximum(for: index)
    {
      // Keep a usable one-digit draft when the second digit would cross this
      // segment's bound. The user can immediately replace it with a valid one.
      accepted = String(digits.prefix(1))
    } else {
      accepted = digits
    }

    if accepted != raw {
      setField(index, value: accepted)
    }
    publishCurrentValue()

    // A complete two-digit entry advances naturally, just like a native
    // segmented date control. The selected segment itself remains selected on
    // external SwiftUI updates because those updates are ignored while active.
    if accepted.count == 2, raw == accepted {
      focusSegment(index + 1)
    }
  }

  private func normalizeSegment(_ index: Int) {
    guard inputEnabled, fields.indices.contains(index) else { return }
    let raw = String(fields[index].stringValue.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
    let normalized: String
    if raw.isEmpty { normalized = "00" }
    else if raw.count == 1 { normalized = "0" + raw }
    else if let value = Int(raw), value <= Self.maximum(for: index) {
      normalized = String(format: "%02d", value)
    } else {
      normalized = raw
    }
    if normalized != fields[index].stringValue {
      setField(index, value: normalized)
      publishCurrentValue()
    }
  }

  private func normalizeAllSegments() {
    for index in fields.indices { normalizeSegment(index) }
  }

  fileprivate func beginValueEdit() {
    isEditingValue = true
    onEdit()
  }

  private func adjustDuration(from index: Int, direction: Int) {
    guard inputEnabled else { return }
    beginValueEdit()
    let values = fields.map { Int($0.stringValue) ?? 0 }
    let total = values[0] * 3600 + values[1] * 60 + values[2]
    let step: Int
    switch index {
    case 0: step = 3600
    case 1: step = 60
    default: step = 1
    }
    let proposed = total + direction * step
    let bounded = min(Self.maximumSeconds, max(1, proposed))
    let next = [bounded / 3600, bounded / 60 % 60, bounded % 60]
      .map { String(format: "%02d", $0) }
    setAllSegments(next, publish: false, selectActive: true)
    publishCurrentValue()
    activeIndex = index
    selectEntireSegment(index)
  }

  private func publishCurrentValue() {
    guard inputEnabled else { return }
    let value = fields.map { Self.padded($0.stringValue) }.joined(separator: ":")
    guard value != lastPublishedText else { return }
    deferredExternalText = nil
    lastPublishedText = value
    onTextChange(value)
    updateAccessibilityLabels()
  }

  private func setAllSegments(_ values: [String], publish: Bool, selectActive: Bool) {
    isApplyingValue = true
    for (field, value) in zip(fields, values) {
      field.stringValue = value
    }
    isApplyingValue = false
    if publish { publishCurrentValue() }
    if selectActive, let activeIndex { selectEntireSegment(activeIndex) }
    updateAccessibilityLabels()
  }

  private func setField(_ index: Int, value: String) {
    guard fields.indices.contains(index) else { return }
    isApplyingValue = true
    fields[index].stringValue = value
    isApplyingValue = false
    if let editor = fields[index].currentEditor() {
      editor.selectedRange = NSRange(location: value.utf16.count, length: 0)
    }
    fields[index].setAccessibilityValue(value)
  }

  private static func maximum(for index: Int) -> Int {
    index == 0 ? maximumHours : maximumMinutesAndSeconds
  }

  private static func padded(_ value: String) -> String {
    let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
    if digits.isEmpty { return "00" }
    if digits.count == 1 { return "0" + digits }
    return digits
  }

  private static func segments(for value: String) -> [String] {
    guard !value.isEmpty else { return ["", "", ""] }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == componentCount else { return ["", "", ""] }
    return parts.map { part in
      let digits = String(part.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
      guard !digits.isEmpty else { return "00" }
      return digits.count == 1 ? "0" + digits : digits
    }
  }
}

/// Separator labels participate in the stack's visual layout at their full
/// glyph width. Drawing this non-editable label without text-field padding
/// keeps the colon visible at the same tight spacing as the native date picker.
@available(macOS 26.0, *)
private final class DurationSeparatorField: NSTextField {
  override var alignmentRectInsets: NSEdgeInsets {
    NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !stringValue.isEmpty else { return }
    let actualFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: actualFont,
      .foregroundColor: textColor ?? .labelColor,
    ]
    let text = stringValue as NSString
    let size = text.size(withAttributes: attributes)
    let rect = NSRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
    text.draw(in: rect, withAttributes: attributes)
  }
}

@available(macOS 26.0, *)
final class DurationSegmentField: NSTextField {
  // The composite is the key-loop entry; segments are reached by its commands.
  override var canBecomeKeyView: Bool { false }

  weak var owner: DurationInputView?
  let index: Int

  init(frame frameRect: NSRect, index: Int) {
    self.index = index
    super.init(frame: frameRect)
    cell = DurationSegmentCell(textCell: "")
  }

  required init?(coder: NSCoder) {
    index = 0
    super.init(coder: coder)
    cell = DurationSegmentCell(textCell: stringValue)
  }

  override func becomeFirstResponder() -> Bool {
    owner?.willFocus(self)
    let accepted = super.becomeFirstResponder()
    if accepted { owner?.didFocus(self) }
    return accepted
  }

  override func mouseDown(with event: NSEvent) {
    owner?.willFocus(self)
    super.mouseDown(with: event)
    owner?.didFocus(self)
  }
}

/// A private editor avoids changing the window's shared text-selection style.
/// Date pickers highlight the active segment even during a partial numeric entry.
@available(macOS 26.0, *)
private final class DurationSegmentCell: NSTextFieldCell {
  private let segmentEditor = DurationSegmentEditor(frame: .zero)

  override func fieldEditor(for controlView: NSView) -> NSTextView? {
    segmentEditor.isFieldEditor = true
    segmentEditor.onEdit = { [weak controlView] in
      guard let field = controlView as? DurationSegmentField, field.owner?.inputEnabled == true else { return }
      field.owner?.beginValueEdit()
    }
    return segmentEditor
  }

  override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
    let editor = super.setUpFieldEditorAttributes(textObj)
    if let editor = editor as? DurationSegmentEditor {
      editor.drawsBackground = false
      editor.textColor = .alternateSelectedControlTextColor
      editor.selectedTextAttributes = [
        .foregroundColor: NSColor.alternateSelectedControlTextColor,
        .backgroundColor: NSColor.clear,
      ]
    }
    return editor
  }
}

@available(macOS 26.0, *)
private final class DurationSegmentEditor: NSTextView {
  var onEdit: () -> Void = {}

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
    guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return }
    onEdit()
    super.insertText(insertString, replacementRange: replacementRange)
  }

  override func deleteBackward(_ sender: Any?) {
    onEdit()
    super.deleteBackward(sender)
  }

  override func deleteForward(_ sender: Any?) {
    onEdit()
    super.deleteForward(sender)
  }

  override func didChangeText() {
    super.didChangeText()
    textColor = .alternateSelectedControlTextColor
    typingAttributes[.foregroundColor] = NSColor.alternateSelectedControlTextColor
  }

  override func draw(_ dirtyRect: NSRect) {
    if textColor != .alternateSelectedControlTextColor {
      textColor = .alternateSelectedControlTextColor
    }
    // Use the same semantic accent as selected native controls, rather than
    // the translucent document-text selection color used by NSTextField.
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    super.draw(dirtyRect)
  }

  override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
    // Numeric entry still uses AppKit's insertion range internally. The visible
    // selection belongs to the whole segment, just as it does in NSDatePicker.
  }
}
