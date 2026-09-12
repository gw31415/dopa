import AppKit
import DopaProtocol
@testable import DopaUI
import DopaUIModel
import SwiftUI
import XCTest

@available(macOS 26.0, *)
@MainActor
final class PanelLayoutTests: XCTestCase {
  func testSessionSettingsAndAggregateDisplayStatusKeepPanelSize() async throws {
    let snapshot = try DaemonSnapshot(.object([
      "instanceId": .string("session-settings"), "revision": .string("1"),
      "phase": .string("active"), "recoveryPending": .bool(false),
      "confirmed": .object(["systemSleepDisabled": .bool(true), "keepDisplayOn": .bool(true)]),
      "sessions": .array([
        .object(["id": .string("cli-one"), "clientName": .string("dopa CLI"),
          "peerUID": .number(501), "peerPID": .number(12001),
          "options": .object(["keepDisplayOn": .bool(false), "stopOnLidClose": .bool(true)])]),
        .object(["id": .string("cli-two"), "clientName": .string("dopa CLI"),
          "peerUID": .number(501), "peerPID": .number(12002),
          "options": .object(["keepDisplayOn": .bool(true), "stopOnLidClose": .bool(false)])]),
      ]),
    ]))
    let model = AppModel(transport: LayoutTransport(snapshot: snapshot,
      capabilities: ["session.stopSessions"]), currentUID: 501)
    try await model.connectOnce()
    XCTAssertFalse(model.options.keepDisplayOn)
    XCTAssertEqual(model.displaySleepPrevented, true)
    XCTAssertTrue(model.canStopAll)
    let selection = SelectionBox()
    let host = NSHostingView(rootView: panel(model: model, selection: selection))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer { window.contentView = nil }
    let ownSize = layout(host, in: window)
    try writeSnapshot(of: host, name: "panel-display-prevented")
    selection.value = 1
    host.rootView = panel(model: model, selection: selection)
    let globalSize = layout(host, in: window)
    XCTAssertEqual(globalSize, ownSize)
    try writeSnapshot(of: host, name: "panel-session-settings")
  }

  func testPopoverControllerKeepsItsFrameAcrossStartEditCancelAndStop() async throws {
    let transport = StatusLayoutTransport(snapshot: try initialSnapshot())
    let model = AppModel(transport: transport)
    try await model.connectOnce()
    let controller = PanelHostingController(rootView: panel(model: model, selection: SelectionBox()))
    let size = controller.prepareSize()
    XCTAssertGreaterThan(size.height, 300)
    XCTAssertLessThan(size.height, 600)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 300, y: 300), size: size),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentViewController = controller
    let originalFrame = window.frame
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.contentSize = size
    defer { window.contentViewController = nil; popover.contentViewController = nil }

    func assertStableFrame() async {
      await Task.yield()
      controller.view.layoutSubtreeIfNeeded()
      XCTAssertEqual(controller.preferredContentSize, size)
      XCTAssertEqual(popover.contentSize, size)
      XCTAssertEqual(window.frame, originalFrame)
      XCTAssertLessThanOrEqual(controller.view.fittingSize.height, size.height + 1)
    }
    let start = Task { await model.start() }
    await transport.waitForAcquire()
    await assertStableFrame()
    await transport.finishAcquire()
    await start.value
    await assertStableFrame()
    model.editDuration("02:00:00")
    await assertStableFrame()
    model.cancelEdit()
    await assertStableFrame()
    await model.stop()
    await assertStableFrame()
  }

  func testPanelSizeDoesNotChangeForMessagesConnectionOrBusyState() async throws {
    let transport = StatusLayoutTransport(snapshot: try initialSnapshot())
    let model = AppModel(transport: transport)
    let selection = SelectionBox()
    let hostingView = NSHostingView(rootView: panel(model: model, selection: selection))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = hostingView
    defer { window.contentView = nil }
    _ = layout(hostingView, in: window)
    let expected = layout(hostingView, in: window)

    func assertStableSize() {
      let actual = layout(hostingView, in: window)
      XCTAssertEqual(actual.width, expected.width, accuracy: 1)
      XCTAssertEqual(actual.height, expected.height, accuracy: 1)
    }

    try await model.connectOnce()
    assertStableSize()
    model.message = String(repeating: "接続と電源設定を確認してください。\n", count: 12)
    assertStableSize()
    selection.value = 1
    hostingView.rootView = panel(model: model, selection: selection)
    assertStableSize()
    selection.value = 0
    hostingView.rootView = panel(model: model, selection: selection)
    model.message = nil
    assertStableSize()

    let start = Task { await model.start() }
    await transport.waitForAcquire()
    XCTAssertTrue(model.busy)
    assertStableSize()
    await transport.finishAcquire()
    await start.value
    assertStableSize()
    do { try await model.pollOnce(); XCTFail("Expected disconnect") } catch {}
    XCTAssertEqual(model.connectionState, .disconnected)
    assertStableSize()
  }

  func testInitialPanelRendersOffscreenAndWritesSnapshot() async throws {
    let snapshot = try initialSnapshot()
    let model = AppModel(transport: LayoutTransport(snapshot: snapshot))
    try await model.connectOnce()

    let selection = SelectionBox()
    let hostingView = NSHostingView(rootView: panel(model: model, selection: selection))
    hostingView.frame = NSRect(x: 0, y: 0, width: 440, height: 700)

    // Keep the window unattached to the desktop. In particular, this test does
    // not order it front, make it key, send input, or query accessibility.
    let window = NSWindow(
      contentRect: hostingView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    window.appearance = NSAppearance(named: .aqua)
    window.backgroundColor = .windowBackgroundColor
    hostingView.wantsLayer = true
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    window.contentView = hostingView
    defer { window.contentView = nil }

    let ownSize = layout(hostingView, in: window)
    XCTAssertEqual(ownSize.width, 380, accuracy: 1)
    XCTAssertLessThan(ownSize.width, 600)
    XCTAssertGreaterThan(ownSize.height, 300)
    XCTAssertLessThan(ownSize.height, 900)
    assertTimeFieldAlignment(in: hostingView)
    try writeSnapshot(of: hostingView)
    try writeSnapshot(of: hostingView, name: "panel-duration-focus") { view in
      let control = self.descendants(of: view).compactMap { $0 as? DurationFieldControl }.first
      XCTAssertNotNil(control)
      XCTAssertTrue(view.window?.makeFirstResponder(control) == true)
    }
    try writeSnapshot(of: hostingView, name: "panel-date-edit-focus") { view in
      let control = self.descendants(of: view).compactMap { $0 as? DateTimeFieldControl }.first
      XCTAssertNotNil(control)
      XCTAssertTrue(control?.startEditing() == true)
    }

    selection.value = 1
    hostingView.rootView = panel(model: model, selection: selection)
    let globalSize = layout(hostingView, in: window)
    XCTAssertEqual(globalSize.width, ownSize.width, accuracy: 1)
    XCTAssertEqual(globalSize.height, ownSize.height, accuracy: 1)

    try writeSnapshot(of: hostingView, name: "panel-global")

    selection.value = 0
    hostingView.rootView = panel(model: model, selection: selection)
    let restoredSize = layout(hostingView, in: window)
    XCTAssertEqual(restoredSize.width, ownSize.width, accuracy: 1)
    XCTAssertEqual(restoredSize.height, ownSize.height, accuracy: 1)

    let nativePicker = try XCTUnwrap(descendants(of: hostingView).compactMap { $0 as? NSDatePicker }.first)
    XCTAssertTrue(window.makeFirstResponder(nativePicker))
    XCTAssertEqual(model.schedule.basis, .duration)
    nativePicker.dateValue = model.now.addingTimeInterval(3600)
    XCTAssertTrue(nativePicker.sendAction(nativePicker.action, to: nativePicker.target))
    XCTAssertEqual(model.schedule.basis, .end)
    let fixedTarget = model.schedule.target(now: model.now)
    XCTAssertEqual(model.schedule.target(now: model.now.addingTimeInterval(30)), fixedTarget)
    _ = layout(hostingView, in: window)
    try writeSnapshot(of: hostingView, name: "panel-fixed-date")
    let nativeDuration = try XCTUnwrap(descendants(of: hostingView).compactMap { $0 as? NSTextField }
      .first { $0.isEditable && !isInsideDatePicker($0) })
    XCTAssertTrue(window.makeFirstResponder(nativeDuration))
    _ = layout(hostingView, in: window)
    await Task.yield()
    XCTAssertEqual(model.schedule.basis, .end)
    window.makeFirstResponder(nil)

    model.setUnlimited(true)
    let unlimitedSize = layout(hostingView, in: window)
    XCTAssertEqual(unlimitedSize.width, ownSize.width, accuracy: 1)
    XCTAssertEqual(unlimitedSize.height, ownSize.height, accuracy: 1)
    assertTimeFieldAlignment(in: hostingView)
    let unlimitedPicker = descendants(of: hostingView).compactMap { $0 as? NSDatePicker }.first
    XCTAssertEqual(unlimitedPicker?.isHidden, true)
    XCTAssertEqual(unlimitedPicker?.isEnabled, false)
    let durationSegments = descendants(of: hostingView).compactMap { $0 as? NSTextField }
      .filter { $0.isEditable && !isInsideDatePicker($0) }
    XCTAssertEqual(durationSegments.count, 3)
    XCTAssertTrue(durationSegments.allSatisfy { !$0.isEnabled && $0.stringValue.isEmpty })
    XCTAssertFalse(model.schedule.canAddTime(900, now: model.now))
    try writeSnapshot(of: hostingView, name: "panel-unlimited")

    model.setUnlimited(false)
    await model.start()
    XCTAssertTrue(model.schedule.running)
    XCTAssertEqual(model.schedule.basis, .end)
    let appliedDeadline = model.schedule.deadline
    model.setUnlimited(true)
    XCTAssertTrue(model.schedule.proposedIsUnlimited)
    XCTAssertFalse(model.schedule.config.isUnlimited)
    XCTAssertEqual(model.schedule.deadline, appliedDeadline)
    XCTAssertEqual(layout(hostingView, in: window).height, ownSize.height, accuracy: 1)
    model.cancelEdit()
    XCTAssertFalse(model.schedule.proposedIsUnlimited)
    model.setUnlimited(true)
    model.applyEdit()
    XCTAssertTrue(model.schedule.config.isUnlimited)
    XCTAssertNil(model.schedule.deadline)
    model.setUnlimited(false)
    XCTAssertFalse(model.schedule.proposedIsUnlimited)
    XCTAssertTrue(model.schedule.config.isUnlimited)
    XCTAssertEqual(layout(hostingView, in: window).height, ownSize.height, accuracy: 1)
    model.cancelEdit()
    XCTAssertTrue(model.schedule.proposedIsUnlimited)
    model.setUnlimited(false)
    model.applyEdit()
    XCTAssertEqual(model.schedule.basis, .end)
    _ = layout(hostingView, in: window)
    assertTimeFieldAlignment(in: hostingView)
    try writeSnapshot(of: hostingView, name: "panel-running")
    model.editDuration("02:00:00")
    let editingSize = layout(hostingView, in: window)
    XCTAssertEqual(editingSize.height, ownSize.height, accuracy: 1)
    assertTimeFieldAlignment(in: hostingView)
    try writeSnapshot(of: hostingView, name: "panel-editing")
    model.cancelEdit()
    window.appearance = NSAppearance(named: .darkAqua)
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    _ = layout(hostingView, in: window)
    assertTimeFieldAlignment(in: hostingView)
    try writeSnapshot(of: hostingView, name: "panel-dark")

  }

  private func writeSnapshot(
    of source: NSHostingView<DopaPanel>, name: String = "panel",
    prepare: (NSView) -> Void = { _ in }
  ) throws {
    // A fresh backing tree avoids partially cached layers after tab/appearance changes.
    let hostingView = NSHostingView(rootView: source.rootView.environment(
      \.colorScheme, source.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light))
    hostingView.frame = source.bounds
    let window = NSWindow(contentRect: source.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = source.effectiveAppearance
    hostingView.wantsLayer = true
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    window.contentView = hostingView
    defer { window.contentView = nil }
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    prepare(hostingView)
    let bounds = hostingView.bounds.integral
    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
      XCTFail("NSHostingView did not provide a bitmap representation")
      return
    }
    hostingView.effectiveAppearance.performAsCurrentDrawingAppearance {
      hostingView.cacheDisplay(in: bounds, to: bitmap)
    }
    guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
      XCTFail("NSHostingView bitmap could not be encoded as PNG")
      return
    }

    let outputURL = packageRoot
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("ui-acceptance", isDirectory: true)
      .appendingPathComponent("\(name).png")
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: outputURL, options: Data.WritingOptions.atomic)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    XCTAssertGreaterThan(png.count, 128)
  }

  private func panel(model: AppModel, selection: SelectionBox) -> DopaPanel {
    DopaPanel(model: model, selection: Binding(
      get: { selection.value },
      set: { selection.value = $0 }
    ))
  }

  private func layout(_ view: NSHostingView<DopaPanel>, in window: NSWindow) -> CGSize {
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    let size = view.fittingSize
    view.frame = NSRect(origin: .zero, size: size)
    window.setContentSize(size)
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    return size
  }

  private func assertTimeFieldAlignment(in view: NSHostingView<DopaPanel>) {
    let durationFields = descendants(of: view).compactMap { $0 as? DurationInputView }
    let datePickers = descendants(of: view)
      .compactMap { $0 as? NSDatePicker }
      .filter { $0.bounds.width > 100 }
    guard let durationField = durationFields.first, let datePicker = datePickers.first else {
      XCTFail(
        "expected one segmented DurationInputView and one NSDatePicker, found "
          + "duration=\(durationFields.count), datePicker=\(datePickers.count)"
      )
      return
    }
    // Native controls include different internal drawing insets. Compare their
    // layout alignment rectangles within the shared field decoration.
    let durationRect = view.convert(
      durationField.alignmentRect(forFrame: durationField.frame), from: durationField.superview)
    let datePickerRect = view.convert(
      datePicker.alignmentRect(forFrame: datePicker.frame), from: datePicker.superview)

    for editor in [durationField as NSView, datePicker as NSView] {
      guard let control = editor.superview as? TimeFieldControl else {
        XCTFail("numeric editor must be inside the shared field control")
        continue
      }
      XCTAssertEqual(control.bounds.width, 220, accuracy: 1)
      XCTAssertEqual(control.bounds.height, 24, accuracy: 1)
      XCTAssertEqual(control.focusRingMaskBounds, control.bounds)
      let visibleEditor = editor.alignmentRect(forFrame: editor.frame)
      XCTAssertEqual(visibleEditor.maxX, control.bounds.maxX - 10, accuracy: 1)
      XCTAssertEqual(visibleEditor.midY, control.bounds.midY, accuracy: 1)
    }

    for segment in durationField.segmentFields {
      let textWidth = ("00" as NSString).size(withAttributes: [.font: segment.font!]).width
      XCTAssertGreaterThanOrEqual(segment.bounds.width, textWidth)
      XCTAssertGreaterThanOrEqual(segment.bounds.height, 16)
    }
    XCTAssertTrue(datePicker.datePickerElements.contains(.yearMonthDay))
    XCTAssertTrue(datePicker.datePickerElements.contains(.hourMinuteSecond))
    XCTAssertEqual(durationRect.height, datePickerRect.height, accuracy: 1)
    XCTAssertEqual(durationRect.maxX, datePickerRect.maxX, accuracy: 1)
    let secondsField = durationField.segmentFields[2]
    let secondsRect = view.convert(secondsField.alignmentRect(forFrame: secondsField.frame), from: secondsField.superview)
    XCTAssertEqual(secondsRect.maxX, datePickerRect.maxX, accuracy: 1)
    XCTAssertEqual(abs(datePickerRect.midY - durationRect.midY), 36, accuracy: 1)
    XCTAssertGreaterThanOrEqual(datePicker.bounds.width, datePicker.intrinsicContentSize.width)
  }

  private func isInsideDatePicker(_ view: NSView) -> Bool {
    var ancestor = view.superview
    while let current = ancestor {
      if current is NSDatePicker { return true }
      ancestor = current.superview
    }
    return false
  }

  private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }

  private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func initialSnapshot() throws -> DaemonSnapshot {
    try DaemonSnapshot(.object([
      "instanceId": .string("ui-layout-test"),
      "revision": .string("1"),
      "phase": .string("idle"),
      "sessions": .array([]),
      "recoveryPending": .bool(false),
      "confirmed": .object([
        "systemSleepDisabled": .bool(false),
        "keepDisplayOn": .bool(false),
      ]),
    ]))
  }
}

@MainActor
private final class SelectionBox {
  var value = 0
}

private struct LayoutTransport: DaemonTransport {
  let snapshot: DaemonSnapshot
  var capabilities: Set<String> = []

  func connect() async throws -> DaemonHandshake {
    DaemonHandshake(capabilities: capabilities, snapshot: snapshot)
  }

  func request(method: String, params: JSONValue) async throws -> JSONValue {
    if method == "session.acquire" {
      return .object(["sessionId": .string("layout-own"), "revision": .string("2")])
    }
    return .object([
      "instanceId": .string("ui-layout-test"), "revision": .string("1"),
      "phase": .string("idle"), "sessions": .array([]), "recoveryPending": .bool(false),
      "confirmed": .object(["systemSleepDisabled": .bool(false), "keepDisplayOn": .bool(false)]),
    ])
  }

  func poll() async throws -> [JSONValue] { [] }
  func close() async {}
}

private actor StatusLayoutTransport: DaemonTransport {
  let snapshot: DaemonSnapshot
  private var acquire: CheckedContinuation<JSONValue, Never>?
  private var acquireWaiter: CheckedContinuation<Void, Never>?

  init(snapshot: DaemonSnapshot) { self.snapshot = snapshot }
  func connect() async throws -> DaemonHandshake {
    DaemonHandshake(capabilities: [], snapshot: snapshot)
  }
  func request(method: String, params: JSONValue) async throws -> JSONValue {
    if method == "session.acquire" {
      return await withCheckedContinuation { continuation in
        acquire = continuation
        acquireWaiter?.resume()
        acquireWaiter = nil
      }
    }
    return try await LayoutTransport(snapshot: snapshot).request(method: method, params: params)
  }
  func waitForAcquire() async {
    if acquire != nil { return }
    await withCheckedContinuation { acquireWaiter = $0 }
  }
  func finishAcquire() {
    acquire?.resume(returning: .object(["sessionId": .string("layout-own"), "revision": .string("2")]))
    acquire = nil
  }
  func poll() async throws -> [JSONValue] { throw URLError(.notConnectedToInternet) }
  func close() async {}
}
