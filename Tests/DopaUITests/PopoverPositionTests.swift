import AppKit
import DopaProtocol
@testable import DopaUI
import DopaUIModel
import SwiftUI
import XCTest

@available(macOS 26.0, *)
@MainActor
final class PopoverPositionTests: XCTestCase {
  func testActualPopoverFrameAcrossStatusSymbolAndRunningChanges() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    let model = AppModel(transport: PositionTransport())
    try await model.connectOnce()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let button = try XCTUnwrap(item.button)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    func updateImage() {
      button.image = NSImage(systemSymbolName: model.statusSymbol, accessibilityDescription: model.status)
      button.image?.isTemplate = true
    }
    updateImage()
    try await Task.sleep(for: .milliseconds(100))
    let controller = PanelHostingController(rootView: DopaPanel(model: model, selection: .constant(0)))
    let popover = NSPopover()
    popover.animates = true
    popover.contentViewController = controller
    popover.contentSize = controller.prepareSize()
    popover.show(relativeToStatusButton: button)
    defer {
      popover.close()
      NSStatusBar.system.removeStatusItem(item)
    }
    let window = try XCTUnwrap(controller.view.window)
    window.alphaValue = 0
    try await Task.sleep(for: .milliseconds(400))
    // Reposition after the new status item has joined its menu-bar window.
    popover.show(relativeToStatusButton: button)
    try await Task.sleep(for: .milliseconds(100))
    let expected = window.frame
    let anchor = try XCTUnwrap(button.window?.contentView)
    let anchorFrame = anchor.frame
    let contentFrame = controller.view.frame
    let size = popover.contentSize
    XCTAssertGreaterThan(anchorFrame.height, 0)
    for _ in 0..<3 {
      await model.start()
      XCTAssertEqual(model.statusSymbol, "cup.and.saucer.fill")
      updateImage()
      for _ in 0..<5 {
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(window.frame, expected)
        XCTAssertEqual(anchor.frame, anchorFrame)
        XCTAssertEqual(controller.view.frame, contentFrame)
        XCTAssertEqual(popover.contentSize, size)
      }
      await model.stop()
      XCTAssertEqual(model.statusSymbol, "moon")
      updateImage()
      for _ in 0..<5 {
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(window.frame, expected)
        XCTAssertEqual(anchor.frame, anchorFrame)
        XCTAssertEqual(controller.view.frame, contentFrame)
        XCTAssertEqual(popover.contentSize, size)
      }
    }
  }
}

private actor PositionTransport: DaemonTransport {
  private var running = false
  private var revision = 1
  func connect() async throws -> DaemonHandshake {
    try DaemonHandshake(capabilities: [], snapshot: DaemonSnapshot(status))
  }
  func request(method: String, params: JSONValue) async throws -> JSONValue {
    try await Task.sleep(for: .milliseconds(50))
    if method == "session.acquire" {
      running = true
      revision += 1
      return .object(["sessionId": .string("position-own"), "revision": .string(String(revision))])
    }
    if method == "session.release" {
      running = false
      revision += 1
      return .object(["revision": .string(String(revision))])
    }
    return status
  }
  func poll() async throws -> [JSONValue] { [] }
  func close() async {}
  private var status: JSONValue {
    let session: JSONValue = .object([
      "id": .string("position-own"), "clientName": .string("dopa UI"), "peerPID": .number(123),
      "options": .object(["keepDisplayOn": .bool(false), "stopOnLidClose": .bool(false)]),
    ])
    return .object([
      "instanceId": .string("position-test"), "revision": .string(String(revision)),
      "phase": .string(running ? "active" : "idle"), "sessions": .array(running ? [session] : []),
      "recoveryPending": .bool(false),
      "confirmed": .object(["systemSleepDisabled": .bool(running), "keepDisplayOn": .bool(false)]),
    ])
  }
}
