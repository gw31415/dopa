import AppKit
@testable import DopaUI
import XCTest

@available(macOS 26.0, *)
@MainActor
final class PopoverFocusTests: XCTestCase {
  func testPreparedInitialResponderDoesNotSelectAnEditableField() {
    let fixture = Fixture()
    var focusCallbacks = 0
    fixture.duration.onFocus = { focusCallbacks += 1 }

    fixture.window.initialFirstResponder = fixture.initialFocus
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.initialFocus))
    XCTAssertTrue(fixture.window.firstResponder === fixture.initialFocus)
    XCTAssertNil(fixture.duration.segmentFields[0].currentEditor())
    XCTAssertEqual(focusCallbacks, 0)
  }

  func testNeutralResponderEntersTheNormalKeyViewLoopOnTab() throws {
    let fixture = Fixture()
    fixture.initialFocus.tabTarget = fixture.control
    fixture.window.initialFirstResponder = fixture.initialFocus
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.initialFocus))

    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: fixture.window.windowNumber,
      context: nil,
      characters: "\t",
      charactersIgnoringModifiers: "\t",
      isARepeat: false,
      keyCode: 48
    ))
    fixture.initialFocus.keyDown(with: event)

    XCTAssertTrue(fixture.window.firstResponder === fixture.control)
    XCTAssertNil(fixture.duration.segmentFields[0].currentEditor())
    XCTAssertFalse(fixture.control.isEditing)
  }

  func testReopenRestoresNeutralResponderAfterAnIntentionalEdit() {
    let fixture = Fixture()
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.duration.segmentFields[0]))
    XCTAssertTrue(fixture.duration.segmentFields[0].currentEditor() != nil)

    // NSPopover reuses its content controller. This is the same preparation
    // performed by DopaAppDelegate's popoverWillShow callback on every show.
    fixture.window.initialFirstResponder = fixture.initialFocus
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.initialFocus))
    XCTAssertTrue(fixture.window.firstResponder === fixture.initialFocus)
    XCTAssertNil(fixture.duration.segmentFields[0].currentEditor())
  }

  @MainActor
  private final class Fixture {
    let window: NSWindow
    let initialFocus = PopoverInitialFocusView(frame: .zero)
    let control = DurationFieldControl()
    var duration: DurationInputView { control.input }

    init() {
      let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
      window = NSWindow(
        contentRect: root.bounds,
        styleMask: [.borderless],
        backing: .buffered,
        defer: true
      )
      window.contentView = root
      duration.update(text: "01:02:03", isEnabled: true, accessibilityLabel: "継続時間")
      control.frame = NSRect(x: 10, y: 40, width: duration.intrinsicContentSize.width, height: 16)
      root.addSubview(control)
      root.addSubview(initialFocus)
      root.layoutSubtreeIfNeeded()
    }
  }
}
