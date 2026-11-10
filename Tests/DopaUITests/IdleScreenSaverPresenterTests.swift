import AppKit
import XCTest
@testable import DopaUI

@available(macOS 26.0, *)
@MainActor
final class IdleScreenSaverPresenterTests: XCTestCase {
  func testPresentCoversEveryScreenAndDismissRemovesTheWindows() throws {
    let screens = NSScreen.screens
    try XCTSkipIf(screens.isEmpty, "No display is attached")
    let presenter = IdleScreenSaverPresenter()
    defer { presenter.dismiss() }

    presenter.present()
    XCTAssertTrue(presenter.isPresented)
    let windows = presenter.presentedWindows
    XCTAssertEqual(windows.map(\.frame), screens.map(\.frame))
    for window in windows {
      XCTAssertEqual(window.level, .screenSaver)
      XCTAssertTrue(window.canBecomeKey)
      XCTAssertTrue(window.isVisible)
    }

    presenter.present()
    XCTAssertEqual(presenter.presentedWindows.count, screens.count)

    presenter.dismiss()
    XCTAssertFalse(presenter.isPresented)
    XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
  }
}
