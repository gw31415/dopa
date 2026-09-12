import AppKit
import SwiftUI
import DopaUIModel
@testable import DopaUI
import XCTest

@available(macOS 26.0, *)
@MainActor
final class NativeDurationFieldTests: XCTestCase {
  func testHostedPanelRepeatedKeyboardTraversal() async throws {
    let model = AppModel()
    let host = NSHostingView(rootView: DopaPanel(model: model, selection: .constant(0)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    window.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let duration = try XCTUnwrap(descendants(host).compactMap { $0 as? DurationFieldControl }.first)
    let date = try XCTUnwrap(descendants(host).compactMap { $0 as? DateTimeFieldControl }.first)
    window.recalculateKeyViewLoop()
    XCTAssertTrue(window.makeFirstResponder(duration))
    func key(_ characters: String, code: UInt16, backward: Bool = false) async throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: backward ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code))
      window.sendEvent(event)
      await Task.yield()
      host.layoutSubtreeIfNeeded()
    }
    for backward in [false, true] {
      for _ in 0..<3 {
        try await key(backward ? "\u{19}" : "\t", code: 48, backward: backward)
        XCTAssertTrue(window.firstResponder === date)
        XCTAssertFalse(date.isEditing)
        try await key(backward ? "\u{19}" : "\t", code: 48, backward: backward)
        XCTAssertTrue(window.firstResponder === duration)
        XCTAssertFalse(duration.isEditing)
      }
    }
    try await key("\r", code: 36)
    XCTAssertTrue(duration.isEditing)
    XCTAssertNil(model.schedule.draft)
    try await key("\t", code: 48)
    XCTAssertTrue(window.firstResponder === duration.input.segmentFields[1].currentEditor())
    XCTAssertTrue(duration.isEditing)
    try await key("\t", code: 48)
    XCTAssertTrue(window.firstResponder === duration.input.segmentFields[2].currentEditor())
    XCTAssertTrue(duration.isEditing)
    try await key("\t", code: 48)
    XCTAssertTrue(window.firstResponder === date)
    XCTAssertFalse(duration.isEditing)
    try await key("\r", code: 36)
    XCTAssertTrue(date.isEditing)
    XCTAssertNil(model.schedule.draft)
    try await key("\u{19}", code: 48, backward: true)
    XCTAssertTrue(window.firstResponder === duration)
    XCTAssertFalse(date.isEditing)
    XCTAssertNil(model.schedule.draft)
  }


  func testSegmentHighlightUsesAnIsolatedEditorThroughoutPartialEntry() throws {
    let fixture = Fixture(text: "01:02:03")
    try fixture.focus(2)
    let editor = try XCTUnwrap(fixture.input.segmentFields[2].currentEditor() as? NSTextView)
    let sharedEditor = try XCTUnwrap(fixture.window.fieldEditor(true, for: fixture.after) as? NSTextView)
    XCTAssertFalse(editor === sharedEditor)
    let originalAttributes = sharedEditor.selectedTextAttributes as NSDictionary
    try fixture.type("4", in: 2)
    XCTAssertEqual(editor.string, "4")
    XCTAssertEqual(editor.textColor, .alternateSelectedControlTextColor)
    XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor, .clear)

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      fixture.window.appearance = NSAppearance(named: appearance)
      let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
      editor.cacheDisplay(in: editor.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/ui-acceptance", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent("duration-selection-\(name).png"))
    }
    fixture.window.makeFirstResponder(fixture.after)
    XCTAssertEqual(sharedEditor.selectedTextAttributes as NSDictionary, originalAttributes)
  }

  func testEnterAlwaysStartsEditingAtHours() throws {
    let fixture = Fixture(text: "01:02:03")
    XCTAssertTrue(fixture.control.startEditing())
    XCTAssertTrue(fixture.isFocused(0))
    XCTAssertTrue(fixture.input.focusSegment(2))
    XCTAssertTrue(fixture.isFocused(2))
    fixture.control.endEditing()
    XCTAssertTrue(fixture.window.firstResponder === fixture.control)

    try fixture.pressEnter()

    XCTAssertTrue(fixture.control.isEditing)
    XCTAssertTrue(fixture.isFocused(0))
  }

  func testMouseDownStartsEditingOnTheClickedSegmentWithoutEnter() throws {
    let fixture = Fixture(text: "01:02:03")
    let segment = fixture.input.segmentFields[2]
    let segmentCenter = NSPoint(x: segment.bounds.midX, y: segment.bounds.midY)
    let point = segment.convert(segmentCenter, to: fixture.window.contentView)
    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: fixture.window.windowNumber,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
    fixture.control.mouseDown(with: event)

    XCTAssertTrue(fixture.control.isEditing)
    XCTAssertTrue(fixture.isFocused(2))
    XCTAssertEqual(fixture.input.segmentFields[2].currentEditor()?.selectedRange.length, 2)
  }

  func testTypingAndArrowNavigationOperateOnWholeSegments() throws {
    let fixture = Fixture(text: "01:02:03")
    let view = fixture.input
    var changes: [String] = []
    view.onTextChange = { changes.append($0) }
    try fixture.focus(0)
    XCTAssertEqual(view.segmentFields[0].currentEditor()?.selectedRange, NSRange(location: 0, length: 2))
    try fixture.type("12", in: 0)
    XCTAssertEqual(changes.last, "12:02:03")
    XCTAssertTrue(fixture.isFocused(1))
    try fixture.command(#selector(NSResponder.moveUp(_:)), in: 1)
    XCTAssertEqual(changes.last, "12:03:03")
    try fixture.command(#selector(NSResponder.moveRight(_:)), in: 1)
    XCTAssertTrue(fixture.isFocused(2))
    try fixture.command(#selector(NSResponder.moveDown(_:)), in: 2)
    XCTAssertEqual(changes.last, "12:03:02")
    try fixture.command(#selector(NSResponder.moveLeft(_:)), in: 2)
    XCTAssertTrue(fixture.isFocused(1))
  }

  func testEditIntentPrecedesChangesAndIncludesSameValueInputButNotNavigation() throws {
    let fixture = Fixture(text: "24:00:00")
    var edits: [String] = []
    var changes = 0
    fixture.input.onEdit = { edits.append(fixture.text) }
    fixture.input.onTextChange = { _ in changes += 1 }
    try fixture.focus(0)
    try fixture.command(#selector(NSResponder.moveRight(_:)), in: 0)
    try fixture.command(#selector(NSResponder.moveLeft(_:)), in: 1)
    try fixture.command(#selector(NSResponder.insertNewline(_:)), in: 0)
    XCTAssertTrue(edits.isEmpty)
    XCTAssertFalse(fixture.control.isEditing)
    try fixture.focus(0)
    try fixture.type("24", in: 0)
    XCTAssertEqual(edits, ["24:00:00"])
    XCTAssertEqual(changes, 0)
    try fixture.command(#selector(NSResponder.moveUp(_:)), in: 1)
    XCTAssertEqual(edits, ["24:00:00", "24:00:00"])
    XCTAssertEqual(changes, 0)
    let editor = try XCTUnwrap(fixture.input.segmentFields[1].currentEditor() as? NSTextView)
    editor.deleteBackward(nil)
    XCTAssertEqual(edits.count, 3)
    XCTAssertEqual(edits.last, "24:00:00")
  }

  func testArrowsCarryAndClampWithoutWrappingAtTwentyFourHours() throws {
    let fixture = Fixture(text: "23:59:59")
    var changes: [String] = []
    fixture.input.onTextChange = { changes.append($0) }
    try fixture.focus(2)
    try fixture.command(#selector(NSResponder.moveUp(_:)), in: 2)
    XCTAssertEqual(fixture.text, "24:00:00")
    try fixture.command(#selector(NSResponder.moveUp(_:)), in: 2)
    XCTAssertEqual(fixture.text, "24:00:00")
    try fixture.command(#selector(NSResponder.moveDown(_:)), in: 2)
    XCTAssertEqual(fixture.text, "23:59:59")
    XCTAssertEqual(changes.last, "23:59:59")

    let minimum = Fixture(text: "00:00:01")
    try minimum.focus(2)
    try minimum.command(#selector(NSResponder.moveDown(_:)), in: 2)
    XCTAssertEqual(minimum.text, "00:00:01")
  }

  func testTabTraversesSegmentsBeforeLeavingForAdjacentWholeControl() throws {
    for index in 0..<3 {
      let fixture = Fixture(text: "01:00:00")
      try fixture.focus(index)
      try fixture.pressTab()
      if index < 2 {
        XCTAssertTrue(fixture.isFocused(index + 1))
        XCTAssertTrue(fixture.control.isEditing)
      } else {
        XCTAssertTrue(fixture.window.firstResponder === fixture.after.currentEditor())
        XCTAssertFalse(fixture.control.isEditing)
      }
      try fixture.focus(index)
      try fixture.pressTab(backward: true)
      if index > 0 {
        XCTAssertTrue(fixture.isFocused(index - 1))
        XCTAssertTrue(fixture.control.isEditing)
      } else {
        XCTAssertTrue(fixture.window.firstResponder === fixture.before.currentEditor())
        XCTAssertFalse(fixture.control.isEditing)
      }
    }
  }

  func testRepeatedTabCyclesThroughWholeControlWithoutEnteringSegments() throws {
    let fixture = Fixture(text: "01:00:00")
    fixture.window.autorecalculatesKeyViewLoop = true
    fixture.window.recalculateKeyViewLoop()
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.control))
    for backward in [false, true] {
      for _ in 0..<3 {
        try fixture.pressTab(backward: backward)
        let first = backward ? fixture.before : fixture.after
        XCTAssertTrue(fixture.window.firstResponder === first.currentEditor())
        try fixture.pressTab(backward: backward)
        let second = backward ? fixture.after : fixture.before
        XCTAssertTrue(fixture.window.firstResponder === second.currentEditor())
        try fixture.pressTab(backward: backward)
        XCTAssertTrue(fixture.window.firstResponder === fixture.control)
        XCTAssertFalse(fixture.control.isEditing)
      }
    }
  }

  func testTabSkipsUnlimitedAndHiddenCompositeInBothDirections() throws {
    let fixture = Fixture(text: "01:00:00")
    fixture.window.autorecalculatesKeyViewLoop = true
    fixture.input.update(text: "", isEnabled: false, accessibilityLabel: "継続時間")
    fixture.control.isEnabled = false
    fixture.window.recalculateKeyViewLoop()
    XCTAssertFalse(fixture.input.canBecomeKeyView)
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.before))
    try fixture.pressTab()
    XCTAssertTrue(fixture.window.firstResponder === fixture.after.currentEditor())
    try fixture.pressTab(backward: true)
    XCTAssertTrue(fixture.window.firstResponder === fixture.before.currentEditor())

    fixture.input.update(text: "01:00:00", isEnabled: true, accessibilityLabel: "継続時間")
    fixture.control.isEnabled = true
    fixture.control.isHidden = true
    fixture.window.recalculateKeyViewLoop()
    XCTAssertFalse(fixture.input.canBecomeKeyView)
    try fixture.pressTab()
    XCTAssertTrue(fixture.window.firstResponder === fixture.after.currentEditor())
    try fixture.pressTab(backward: true)
    XCTAssertTrue(fixture.window.firstResponder === fixture.before.currentEditor())
  }

  func testUnlimitedClearsActiveEditingAndDoesNotPublishOnBlur() throws {
    let fixture = Fixture(text: "01:02:03")
    var changes: [String] = []
    fixture.input.onTextChange = { changes.append($0) }
    try fixture.focus(1)
    fixture.input.update(text: "", isEnabled: false, accessibilityLabel: "継続時間")
    fixture.window.makeFirstResponder(fixture.after)
    XCTAssertTrue(fixture.input.segmentFields.allSatisfy { $0.stringValue.isEmpty && !$0.isEnabled })
    XCTAssertTrue(changes.isEmpty)
    XCTAssertFalse(fixture.input.inputEnabled)
    let separators = fixture.input.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSTextField }
      .filter { !$0.isEditable }
    XCTAssertTrue(separators.allSatisfy { $0.isHidden || $0.stringValue.isEmpty })
  }

  func testExternalTickDoesNotReplacePartialInputAndNewEditWinsOnBlur() throws {
    let fixture = Fixture(text: "01:02:03")
    try fixture.focus(0)
    fixture.input.update(text: "01:01:59", isEnabled: true, accessibilityLabel: "継続時間")
    XCTAssertEqual(fixture.text, "01:01:59")
    try fixture.type("2", in: 0)
    XCTAssertEqual(fixture.input.segmentFields[0].stringValue, "2")
    fixture.window.makeFirstResponder(fixture.after)
    XCTAssertEqual(fixture.text, "02:01:59")
    fixture.input.update(text: "03:00:00", isEnabled: true, accessibilityLabel: "継続時間")
    XCTAssertEqual(fixture.text, "03:00:00")
  }

  func testEnteringEditorAloneDoesNotFreezeTicksButTypingDoes() throws {
    let fixture = Fixture(text: "01:02:03")
    try fixture.focus(0)
    fixture.input.update(text: "01:01:59", isEnabled: true, accessibilityLabel: "継続時間")
    XCTAssertEqual(fixture.text, "01:01:59")
    try fixture.type("2", in: 0)
    fixture.input.update(text: "01:01:58", isEnabled: true, accessibilityLabel: "継続時間")
    XCTAssertEqual(fixture.text, "2:01:59")
  }

  func testLatestExternalValueWinsAfterFocusEnds() async throws {
    let fixture = Fixture(text: "01:00:00")
    try fixture.focus(0)
    fixture.input.update(text: "02:00:00", isEnabled: true, accessibilityLabel: "継続時間")
    fixture.input.update(text: "01:00:00", isEnabled: true, accessibilityLabel: "継続時間")
    fixture.window.makeFirstResponder(fixture.after)
    await Task.yield()
    XCTAssertEqual(fixture.text, "01:00:00")
  }

  func testColonsRemainVisibleAtCompactSpacing() throws {
    let fixture = Fixture(text: "01:02:03")
    fixture.window.appearance = NSAppearance(named: .aqua)
    let separators = fixture.input.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSTextField }
      .filter { !$0.isEditable }
    XCTAssertEqual(separators.count, 2)
    for separator in separators {
      let bitmap = try XCTUnwrap(separator.bitmapImageRepForCachingDisplay(in: separator.bounds))
      bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
      separator.effectiveAppearance.performAsCurrentDrawingAppearance {
        separator.cacheDisplay(in: separator.bounds, to: bitmap)
      }
      var inkPixels = 0
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
            color.alphaComponent > 0.5,
            max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 {
            inkPixels += 1
          }
        }
      }
      // A narrow NSTextField can have the right string and geometry while its
      // native cell clips the colon completely. Check the actual rendered ink.
      XCTAssertGreaterThan(inkPixels, 1)
    }
  }

  func testNumericFieldsStayWideEnoughWhenEmptyOrPartiallyEdited() throws {
    let fixture = Fixture(text: "01:00:00")
    let size = fixture.input.intrinsicContentSize
    for field in fixture.input.segmentFields {
      XCTAssertGreaterThanOrEqual(field.bounds.width, ("00" as NSString).size(withAttributes: [.font: field.font!]).width)
    }
    try fixture.focus(0)
    try fixture.type("2", in: 0)
    XCTAssertEqual(fixture.input.intrinsicContentSize, size)
    fixture.input.update(text: "", isEnabled: false, accessibilityLabel: "継続時間")
    XCTAssertEqual(fixture.input.intrinsicContentSize, size)
  }

  @MainActor
  private final class Fixture {
    let window: NSWindow
    let control = DurationFieldControl(frame: .zero)
    var input: DurationInputView { control.input }
    let before = NSTextField(string: "before")
    let after = NSTextField(string: "after")

    init(text: String) {
      let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
      window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
      window.contentView = root
      window.autorecalculatesKeyViewLoop = false
      before.frame = NSRect(x: 10, y: 70, width: 100, height: 20)
      after.frame = NSRect(x: 10, y: 10, width: 100, height: 20)
      input.update(text: text, isEnabled: true, accessibilityLabel: "継続時間")
      control.frame = NSRect(origin: NSPoint(x: 10, y: 40), size: control.intrinsicContentSize)
      root.addSubview(before)
      root.addSubview(control)
      root.addSubview(after)
      before.nextKeyView = control
      control.nextKeyView = after
      after.nextKeyView = before
      root.layoutSubtreeIfNeeded()
    }

    var text: String { input.segmentFields.map(\.stringValue).joined(separator: ":") }

    func focus(_ index: Int) throws {
      XCTAssertTrue(control.startEditing())
      XCTAssertTrue(window.makeFirstResponder(input.segmentFields[index]))
      _ = try XCTUnwrap(input.segmentFields[index].currentEditor())
    }

    func isFocused(_ index: Int) -> Bool {
      guard let editor = input.segmentFields[index].currentEditor() else { return false }
      return window.firstResponder === editor
    }

    func type(_ text: String, in index: Int) throws {
      let editor = try XCTUnwrap(input.segmentFields[index].currentEditor() as? NSTextView)
      editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func pressTab(backward: Bool = false) throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: backward ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: backward ? "\u{19}" : "\t", charactersIgnoringModifiers: backward ? "\u{19}" : "\t",
        isARepeat: false, keyCode: 48))
      window.firstResponder?.keyDown(with: event)
    }

    func pressEnter() throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
      window.firstResponder?.keyDown(with: event)
    }

    func command(_ selector: Selector, in index: Int) throws {
      let editor = try XCTUnwrap(input.segmentFields[index].currentEditor() as? NSTextView)
      XCTAssertTrue(input.control(input.segmentFields[index], textView: editor, doCommandBy: selector))
    }
  }
}
