import AppKit
import SwiftUI

/// A native date-and-time field, including seconds, sized by the surrounding form.
@available(macOS 26.0, *)
struct NativeDateTimeField: NSViewRepresentable {
  @Binding var value: Date?
  var isFixed = false
  var onFocus: () -> Void = {}
  var onEdit: () -> Void = {}
  var onEditingChanged: (Bool) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> DateTimeFieldControl {
    let control = DateTimeFieldControl(frame: .zero)
    let picker = control.picker
    picker.datePickerStyle = .textField
    picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
    picker.datePickerMode = .single
    // This numeric locale presents yyyy-MM-dd HH:mm:ss without replacing native date editing.
    picker.locale = Locale(identifier: "sv_SE")
    picker.calendar = Calendar(identifier: .gregorian)
    picker.isBezeled = false
    picker.isBordered = false
    picker.drawsBackground = false
    picker.font = .systemFont(ofSize: NSFont.systemFontSize)
    picker.alignment = .right
    picker.focusRingType = .none
    picker.setContentHuggingPriority(.required, for: .horizontal)
    picker.onEdit = { context.coordinator.parent.onEdit() }
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.changed(_:))
    picker.setAccessibilityLabel("終了日時")
    picker.setAccessibilityIdentifier("end-input")
    control.onFocus = { context.coordinator.parent.onFocus() }
    control.onEditingChanged = { context.coordinator.parent.onEditingChanged($0) }
    control.setAccessibilityLabel("終了日時")
    return control
  }

  func updateNSView(_ control: DateTimeFieldControl, context: Context) {
    let picker = control.picker
    context.coordinator.parent = self
    let enabled = context.environment.isEnabled && value != nil
    control.isEnabled = enabled
    if picker.isEnabled != enabled { picker.isEnabled = enabled }
    if picker.isHidden != (value == nil) { picker.isHidden = value == nil }
    picker.setAccessibilityLabel("終了日時" + (isFixed && value != nil ? "、固定中" : ""))
    // NSDatePicker edits its segments itself: currentEditor() remains nil even
    // while the user is typing. Updating dateValue then discards partial input.
    if let value, !picker.isEditingSegments,
      picker.dateValue != value,
      value.timeIntervalSinceReferenceDate.isFinite {
      picker.dateValue = value
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: DateTimeFieldControl, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: NativeDateTimeField
    init(_ parent: NativeDateTimeField) { self.parent = parent }

    @objc func changed(_ sender: NSDatePicker) {
      parent.onEdit()
      parent.value = sender.dateValue
    }
  }
}

@available(macOS 26.0, *)
final class DateTimeFieldControl: TimeFieldControl {
  let picker = AlignedDatePicker(frame: .zero)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    symbolName = "calendar"
    picker.fieldControl = self
    addSubview(picker)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var editorView: NSView? { picker }

  override func beginFieldEditing() -> Bool {
    picker.resetKeyboardSelection()
    return window?.makeFirstResponder(picker) ?? false
  }

  override func beginFieldEditingFromMouse(with event: NSEvent) -> Bool {
    guard window?.makeFirstResponder(picker) == true else { return false }
    picker.mouseDown(with: event)
    return window?.firstResponder === picker
  }
}

/// The text-only picker retains the padding of its original bezel. Expose that
/// padding to SwiftUI so the visible segments align with adjacent plain text.
@available(macOS 26.0, *)
final class AlignedDatePicker: NSDatePicker {
  weak var fieldControl: TimeFieldControl?
  var onEdit: () -> Void = {}
  private(set) var isEditingSegments = false
  override var canBecomeKeyView: Bool { false }

  /// NSDatePicker retains its last selected segment and exposes no selection
  /// setter. A fresh native cell starts at the first segment without guessing
  /// segment geometry or synthesizing navigation events.
  func resetKeyboardSelection() {
    guard let previous = cell as? NSDatePickerCell else { return }
    let replacement = NSDatePickerCell()
    replacement.datePickerStyle = previous.datePickerStyle
    replacement.datePickerElements = previous.datePickerElements
    replacement.datePickerMode = previous.datePickerMode
    replacement.locale = previous.locale
    replacement.calendar = previous.calendar
    replacement.timeZone = previous.timeZone
    replacement.dateValue = previous.dateValue
    replacement.minDate = previous.minDate
    replacement.maxDate = previous.maxDate
    replacement.timeInterval = previous.timeInterval
    replacement.delegate = previous.delegate
    replacement.isBezeled = previous.isBezeled
    replacement.isBordered = previous.isBordered
    replacement.drawsBackground = previous.drawsBackground
    replacement.backgroundColor = previous.backgroundColor
    replacement.textColor = previous.textColor
    replacement.font = previous.font
    replacement.controlSize = previous.controlSize
    replacement.focusRingType = previous.focusRingType
    replacement.alignment = previous.alignment
    replacement.isEnabled = previous.isEnabled
    replacement.target = previous.target
    replacement.action = previous.action
    cell = replacement
  }

  override func keyDown(with event: NSEvent) {
    let command: Selector? = switch event.keyCode {
    case 36, 76: #selector(NSResponder.insertNewline(_:))
    case 53: #selector(NSResponder.cancelOperation(_:))
    default: nil
    }
    if let command, fieldControl?.handleEditingCommand(command) == true { return }
    let characters = event.charactersIgnoringModifiers ?? ""
    let commandEdit = event.modifierFlags.contains(.command)
      && ["v", "x", "z"].contains(characters.lowercased())
    let numericEdit = !event.modifierFlags.contains(.command)
      && (!characters.isEmpty && characters.allSatisfy { $0 >= "0" && $0 <= "9" }
        || [51, 117, 125, 126].contains(event.keyCode))
    if isEnabled && (commandEdit || numericEdit) {
      isEditingSegments = true
      onEdit()
    }
    super.keyDown(with: event)
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      isEditingSegments = false
      fieldControl?.editorDidResign()
    }
    return accepted
  }

  override func mouseDown(with event: NSEvent) {
    if let fieldControl, !fieldControl.isEditing {
      if isEnabled { fieldControl.startEditing(with: event) }
      return
    }
    super.mouseDown(with: event)
  }

  override var alignmentRectInsets: NSEdgeInsets {
    NSEdgeInsets(top: 2, left: 3, bottom: 3, right: 3)
  }

  override var intrinsicContentSize: NSSize {
    // The borderless picker reports its text size. The shared field lays out
    // an alignment rectangle, so its frame must also include these insets.
    let content = super.intrinsicContentSize
    let insets = alignmentRectInsets
    return NSSize(width: content.width + insets.left + insets.right,
      height: content.height + insets.top + insets.bottom)
  }
}
