import AppKit
import SwiftUI
@testable import DopaUI
import XCTest

@available(macOS 26.0, *)
@MainActor
final class NativeDateTimeFieldTests: XCTestCase {
  func testEditIntentPrecedesMutationAndDoesNotFireForFocusOrNavigation() throws {
    let picker = AlignedDatePicker(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
    picker.datePickerStyle = .textField
    picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
    picker.locale = Locale(identifier: "sv_SE")
    picker.dateValue = Date(timeIntervalSince1970: 1_789_200_000)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView?.addSubview(picker)
    var editStarts: [Date] = []
    picker.onEdit = { [weak picker] in
      if let picker { editStarts.append(picker.dateValue) }
    }
    XCTAssertTrue(window.makeFirstResponder(picker))
    XCTAssertTrue(editStarts.isEmpty)

    func key(_ characters: String, code: UInt16) throws {
      picker.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }
    try key("\u{F703}", code: 124)
    try key("\u{F702}", code: 123)
    XCTAssertTrue(editStarts.isEmpty)
    let before = picker.dateValue
    try key("\u{F700}", code: 126)
    XCTAssertEqual(editStarts, [before])
    try key("2", code: 19)
    XCTAssertEqual(editStarts.count, 2)
    window.makeFirstResponder(nil)
  }
}

@available(macOS 26.0, *)
@MainActor
private final class DateFieldTestModel: ObservableObject {
  @Published var value: Date? = Date(timeIntervalSince1970: 1_789_200_000)
  @Published var fixed = false
}

@available(macOS 26.0, *)
private struct DateFieldTestHost: View {
  @ObservedObject var model: DateFieldTestModel
  var body: some View {
    NativeDateTimeField(value: $model.value, isFixed: model.fixed,
      onEdit: { model.fixed = true }).frame(width: 240, height: 30)
  }
}

@available(macOS 26.0, *)
extension NativeDateTimeFieldTests {
  func testHostedPickerKeepsPartialEditAcrossModelUpdatesAndAcceptsResetAfterBlur() throws {
    let model = DateFieldTestModel()
    let host = NSHostingView(rootView: DateFieldTestHost(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = host
    func flush() {
      RunLoop.main.run(until: Date().addingTimeInterval(0.03))
      host.layoutSubtreeIfNeeded()
    }
    func picker(in view: NSView) -> AlignedDatePicker? {
      (view as? AlignedDatePicker) ?? view.subviews.lazy.compactMap { picker(in: $0) }.first
    }
    flush()
    let field = try XCTUnwrap(picker(in: host))
    let control = try XCTUnwrap(field.superview as? TimeFieldControl)
    XCTAssertTrue(window.makeFirstResponder(control))
    XCTAssertFalse(field.canBecomeKeyView)
    XCTAssertFalse(control.isEditing)
    XCTAssertNil(field.currentEditor(), "NSDatePicker edits segments without a field editor")
    let focusedTick = try XCTUnwrap(model.value).addingTimeInterval(60)
    model.value = focusedTick
    flush()
    XCTAssertEqual(field.dateValue, focusedTick, "Focus alone must not freeze the date")
    XCTAssertFalse(field.isEditingSegments)
    func key(_ characters: String, code: UInt16) throws {
      window.firstResponder?.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
      flush()
    }
    try key("\r", code: 36)
    XCTAssertTrue(control.isEditing)
    XCTAssertTrue(window.firstResponder === field)
    XCTAssertFalse(model.fixed, "Entering edit mode must not fix the date before a value edit")
    try key("2", code: 19)
    XCTAssertTrue(model.fixed)
    let partial = field.dateValue
    model.value = partial.addingTimeInterval(60)
    flush()
    XCTAssertEqual(field.dateValue, partial, "A ticking binding must not overwrite a focused segment edit")
    try key("0", code: 29)
    try key("2", code: 19)
    try key("7", code: 26)
    XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: field.dateValue), 2027)
    XCTAssertEqual(model.value, field.dateValue)
    window.makeFirstResponder(nil)
    XCTAssertFalse(field.isEditingSegments)
    let reset = Date(timeIntervalSince1970: 1_789_300_000)
    model.value = reset
    flush()
    XCTAssertEqual(field.dateValue, reset)

    XCTAssertTrue(window.makeFirstResponder(control))
    try key("\r", code: 36)
    try key("\u{F703}", code: 124)
    try key("\u{F703}", code: 124)
    try key("\u{F703}", code: 124)
    let navigatedTick = reset.addingTimeInterval(60)
    model.value = navigatedTick
    flush()
    XCTAssertFalse(field.isEditingSegments)
    XCTAssertEqual(field.dateValue, navigatedTick)
    try key("\u{F700}", code: 126)
    XCTAssertEqual(field.dateValue, navigatedTick.addingTimeInterval(3_600),
      "A date tick must preserve the hour segment selected by keyboard navigation")
    try key("\r", code: 36)
    XCTAssertFalse(control.isEditing)
    XCTAssertTrue(window.firstResponder === control)
    XCTAssertFalse(field.isEditingSegments)
    window.makeFirstResponder(nil)
  }
}

@available(macOS 26.0, *)
extension NativeDateTimeFieldTests {
  func testNativeTabTraversesAllSixSegmentsAndLeavesTheField() throws {
    let control = DateTimeFieldControl(frame: NSRect(x: 0, y: 50, width: 260, height: 25))
    let picker = control.picker
    picker.datePickerStyle = .textField
    picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
    picker.locale = Locale(identifier: "sv_SE")
    picker.dateValue = Date(timeIntervalSince1970: 1_789_200_000)
    let next = DateTimeFieldControl(frame: NSRect(x: 0, y: 10, width: 260, height: 25))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView?.addSubview(control)
    window.contentView?.addSubview(next)
    window.recalculateKeyViewLoop()
    XCTAssertTrue(window.makeFirstResponder(control))
    XCTAssertTrue(control.startEditing())
    let initial = picker.dateValue
    func key(_ characters: String, _ code: UInt16) throws {
      window.firstResponder?.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }
    for _ in 0..<5 {
      try key("\t", 48)
      XCTAssertTrue(window.firstResponder === picker)
    }
    try key("\u{F700}", 126)
    XCTAssertEqual(picker.dateValue, initial.addingTimeInterval(1))
    try key("\t", 48)
    XCTAssertTrue(window.firstResponder === next)
    XCTAssertTrue(window.makeFirstResponder(control))
    XCTAssertTrue(control.startEditing())
    let before = picker.dateValue
    try key("\u{F700}", 126)
    XCTAssertEqual(Calendar.current.component(.year, from: picker.dateValue),
      Calendar.current.component(.year, from: before) + 1)
    window.makeFirstResponder(nil)
  }
}

@available(macOS 26.0, *)
extension NativeDateTimeFieldTests {
  func testMouseSelectsNativeSegmentAndKeyboardReentryAlwaysSelectsYear() throws {
    let control = DateTimeFieldControl(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
    let picker = control.picker
    picker.datePickerStyle = .textField
    picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
    picker.locale = Locale(identifier: "sv_SE")
    picker.font = .systemFont(ofSize: NSFont.systemFontSize)
    picker.isBezeled = false
    picker.isBordered = false
    picker.alignment = .right
    picker.dateValue = Date(timeIntervalSince1970: 1_789_200_000)
    let window = NSWindow(contentRect: control.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView?.addSubview(control)
    control.layoutSubtreeIfNeeded()
    var edits = 0
    picker.onEdit = { edits += 1 }
    func key(_ characters: String, _ code: UInt16) throws {
      window.firstResponder?.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }
    let font = try XCTUnwrap(picker.font)
    let digitsWidth = ("00" as NSString).size(withAttributes: [.font: font]).width
    let suffixWidth = (":00:00" as NSString).size(withAttributes: [.font: font]).width
    for (offset, increment) in [(digitsWidth / 2 + 3, 1.0), (suffixWidth + digitsWidth / 2 + 3, 3_600.0)] {
      control.endEditing()
      let originalCell = picker.cell
      let before = picker.dateValue
      let point = picker.convert(NSPoint(x: picker.bounds.maxX - offset, y: picker.bounds.midY), to: nil)
      let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
        modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 0))
      NSApp.postEvent(up, atStart: true)
      control.mouseDown(with: down)
      XCTAssertTrue(control.isEditing)
      XCTAssertTrue(window.firstResponder === picker)
      XCTAssertTrue(picker.cell === originalCell, "Mouse entry preserves the native cell and click location")
      XCTAssertEqual(picker.dateValue, before)
      try key("\u{F700}", 126)
      XCTAssertEqual(picker.dateValue, before.addingTimeInterval(increment))
      try key("\r", 36)
      let beforeKeyboardEntry = picker.dateValue
      let editsBeforeEntry = edits
      try key("\r", 36)
      XCTAssertEqual(picker.dateValue, beforeKeyboardEntry)
      XCTAssertEqual(edits, editsBeforeEntry)
      try key("\u{F700}", 126)
      XCTAssertEqual(Calendar.current.component(.year, from: picker.dateValue),
        Calendar.current.component(.year, from: beforeKeyboardEntry) + 1)
    }
    window.makeFirstResponder(nil)
  }
}
