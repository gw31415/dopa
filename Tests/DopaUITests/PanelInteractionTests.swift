import AppKit
import DopaProtocol
@testable import DopaUI
import DopaUIModel
import SwiftUI
import XCTest

@available(macOS 26.0, *)
@MainActor
final class PanelInteractionTests: XCTestCase {
  func testCancelButtonClearsDraftWithoutReturningFocusToTimeInput() async throws {
    let transport = InteractionTransport()
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertTrue(model.schedule.running)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: true)
    let neutral = NeutralResponderView(frame: .zero)
    let host = NSHostingView(rootView: DopaPanel(model: model, selection: .constant(0))
      .environment(\.clearTimeFieldFocus, { window.makeFirstResponder(neutral) }))
    window.contentView = host
    host.addSubview(neutral)
    defer { window.contentView = nil }
    func flush() async {
      try? await Task.sleep(for: .milliseconds(40))
      window.layoutIfNeeded()
      host.layoutSubtreeIfNeeded()
    }
    await flush()
    let control = try XCTUnwrap(descendants(host).compactMap { $0 as? DateTimeFieldControl }.first)
    XCTAssertTrue(window.makeFirstResponder(control))
    control.keyDown(with: try key("\r", code: 36, window: window))
    XCTAssertTrue(control.isEditing)
    control.picker.keyDown(with: try key("\u{F700}", code: 126, window: window))
    await flush()
    XCTAssertNotNil(model.schedule.draft)
    XCTAssertTrue(window.firstResponder === control.picker)
    guard let cancel = accessibilityNodes(host).first(where: {
      $0.accessibilityRole() == .button && $0.accessibilityLabel() == "キャンセル"
    }) else {
      throw XCTSkip("SwiftUI exposes no accessibility children in this test host; actual Cancel button cannot be invoked")
    }
    XCTAssertTrue(cancel.accessibilityPerformPress())
    await flush()
    await flush()
    XCTAssertNil(model.schedule.draft)
    XCTAssertTrue(window.firstResponder === neutral)
    XCTAssertFalse(control.isEditing)
    XCTAssertFalse(control.picker.isEditingSegments)
  }

  func testInvalidIntermediateDateDoesNotStealNativeEditingFocus() async throws {
    let transport = InteractionTransport()
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    await model.start()
    XCTAssertTrue(model.schedule.running)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: true)
    let neutral = NeutralResponderView(frame: .zero)
    let host = NSHostingView(rootView: DopaPanel(model: model, selection: .constant(0))
      .environment(\.clearTimeFieldFocus, { window.makeFirstResponder(neutral) }))
    window.contentView = host
    host.addSubview(neutral)
    defer { window.contentView = nil }
    func flush() async {
      try? await Task.sleep(for: .milliseconds(40))
      window.layoutIfNeeded()
      host.layoutSubtreeIfNeeded()
    }
    await flush()
    let control = try XCTUnwrap(descendants(host).compactMap { $0 as? DateTimeFieldControl }.first)
    XCTAssertTrue(window.makeFirstResponder(control))
    control.keyDown(with: try key("\r", code: 36, window: window))
    XCTAssertTrue(control.isEditing)
    control.picker.keyDown(with: try key("\u{F701}", code: 125, window: window))
    await flush()
    XCTAssertNotNil(model.schedule.draft)
    XCTAssertTrue(window.firstResponder === control.picker)
    XCTAssertNotNil(model.schedule.validation(now: model.now))
    await flush()
    XCTAssertTrue(control.isEditing)
    XCTAssertTrue(window.firstResponder === control.picker)
    XCTAssertTrue(window.childWindows?.isEmpty ?? true)
  }

  private func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }

  private func accessibilityNodes(_ root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
    let children = (root.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
    return children + children.flatMap(accessibilityNodes)
  }

  private func key(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
  }
}

@MainActor
private final class NeutralResponderView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

private struct InteractionTransport: DaemonTransport {
  private var status: JSONValue {
    .object(["instanceId": .string("interaction-test"), "revision": .string("1"),
      "phase": .string("idle"), "sessions": .array([]), "recoveryPending": .bool(false),
      "confirmed": .object(["systemSleepDisabled": .bool(false), "keepDisplayOn": .bool(false)])])
  }
  func connect() async throws -> DaemonHandshake {
    DaemonHandshake(capabilities: [], snapshot: try DaemonSnapshot(status))
  }
  func request(method: String, params: JSONValue) async throws -> JSONValue {
    if method == "session.acquire" {
      return .object(["sessionId": .string("interaction-own"), "revision": .string("2")])
    }
    return status
  }
  func poll() async throws -> [JSONValue] { [] }
  func close() async {}
}
