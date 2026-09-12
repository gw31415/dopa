import AppKit
@testable import DopaUI
import XCTest

@available(macOS 26.0, *)
@MainActor
final class TimeFieldControlTests: XCTestCase {
  func testTabSelectsWholeFieldsAndEnterAloneEntersAndLeavesEditing() throws {
    let fixture = Fixture()
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.first))
    XCTAssertFalse(fixture.first.isEditing)
    try fixture.key("\t", code: 48)
    XCTAssertTrue(fixture.window.firstResponder === fixture.second)
    XCTAssertFalse(fixture.second.isEditing)
    try fixture.key("\u{19}", code: 48, modifiers: [.shift])
    XCTAssertTrue(fixture.window.firstResponder === fixture.first)
    try fixture.key("\r", code: 36)
    XCTAssertTrue(fixture.first.isEditing)
    XCTAssertTrue(fixture.window.firstResponder === fixture.first.field.currentEditor())
    try fixture.key("\r", code: 36)
    XCTAssertFalse(fixture.first.isEditing)
    XCTAssertTrue(fixture.window.firstResponder === fixture.first)
    XCTAssertEqual(fixture.first.finishCount, 1)
  }

  func testTabWhileEditingFinishesThenMovesDirectlyToAnotherWholeField() throws {
    let fixture = Fixture()
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.first))
    try fixture.key("\r", code: 36)
    try fixture.key("\t", code: 48)
    XCTAssertFalse(fixture.first.isEditing)
    XCTAssertTrue(fixture.window.firstResponder === fixture.second)
    try fixture.key("\r", code: 36)
    try fixture.key("\u{19}", code: 48, modifiers: [.shift])
    XCTAssertFalse(fixture.second.isEditing)
    XCTAssertTrue(fixture.window.firstResponder === fixture.first)
  }

  func testOutsideFocusFinishesWithoutTakingFocusBackAndNotifiesAfterCommit() async throws {
    let fixture = Fixture()
    var finishedBeforeNotification = false
    fixture.first.onEditingChanged = { editing in
      if !editing { finishedBeforeNotification = fixture.first.finishCount == 1 }
    }
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.first))
    try fixture.key("\r", code: 36)
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.second))
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    XCTAssertFalse(fixture.first.isEditing)
    XCTAssertTrue(finishedBeforeNotification)
    XCTAssertTrue(fixture.window.firstResponder === fixture.second)
  }

  func testDisabledFieldIsSkippedAndCannotEnterEditing() throws {
    let fixture = Fixture()
    fixture.first.isEnabled = false
    XCTAssertFalse(fixture.first.canBecomeKeyView)
    XCTAssertFalse(fixture.first.startEditing())
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.second))
    try fixture.key("\t", code: 48)
    XCTAssertFalse(fixture.window.firstResponder === fixture.first)
  }

  private final class TestField: NSTextField {
    override var canBecomeKeyView: Bool { false }
  }

  private final class Control: TimeFieldControl, NSTextFieldDelegate {
    let field = TestField(string: "12")
    var finishCount = 0

    override init(frame: NSRect) {
      super.init(frame: frame)
      field.frame = bounds
      field.delegate = self
      addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func beginFieldEditing() -> Bool { window?.makeFirstResponder(field) ?? false }
    override func finishFieldEditing() { finishCount += 1 }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      handleEditingCommand(selector)
    }
    func controlTextDidEndEditing(_ notification: Notification) { editorDidResign() }
  }

  @MainActor
  private final class Fixture {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: true)
    let first = Control(frame: NSRect(x: 10, y: 60, width: 80, height: 24))
    let second = Control(frame: NSRect(x: 10, y: 20, width: 80, height: 24))
    init() {
      window.contentView?.addSubview(first)
      window.contentView?.addSubview(second)
      window.recalculateKeyViewLoop()
    }
    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code))
      window.sendEvent(event)
    }
  }
}
