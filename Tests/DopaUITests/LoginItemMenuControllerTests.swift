import AppKit
import XCTest
@testable import DopaUI

@available(macOS 26.0, *)
@MainActor
final class LoginItemMenuControllerTests: XCTestCase {
  func testMenuStateTracksManagerWheneverMenuOpens() {
    let manager = StubLoginItemManager(status: .disabled)
    let controller = LoginItemMenuController(manager: manager) { _ in }
    let menu = NSMenu()
    menu.delegate = controller

    XCTAssertEqual(controller.menuItem.state, .off)
    manager.status = .enabled
    controller.menuWillOpen(menu)
    XCTAssertEqual(controller.menuItem.state, .on)

    manager.status = .requiresApproval
    controller.menuWillOpen(menu)
    XCTAssertEqual(controller.menuItem.state, .off)
    XCTAssertTrue(controller.menuItem.isEnabled)

    manager.status = .unavailable
    controller.menuWillOpen(menu)
    XCTAssertEqual(controller.menuItem.state, .off)
    XCTAssertFalse(controller.menuItem.isEnabled)
  }

  func testToggleEnablesAndDisablesUsingActualState() {
    let manager = StubLoginItemManager(status: .disabled)
    let controller = LoginItemMenuController(manager: manager) { _ in }

    controller.toggleLoginItem(controller.menuItem)
    XCTAssertEqual(manager.enableCount, 1)
    XCTAssertEqual(manager.disableCount, 0)
    XCTAssertEqual(controller.menuItem.state, .on)

    controller.toggleLoginItem(controller.menuItem)
    XCTAssertEqual(manager.enableCount, 1)
    XCTAssertEqual(manager.disableCount, 1)
    XCTAssertEqual(controller.menuItem.state, .off)
  }

  func testFailedToggleRestoresActualStateAndReportsError() {
    let manager = StubLoginItemManager(status: .disabled)
    manager.enableError = TestError.denied
    var presentedError: (any Error)?
    let controller = LoginItemMenuController(manager: manager) { presentedError = $0 }

    controller.toggleLoginItem(controller.menuItem)

    XCTAssertEqual(manager.enableCount, 1)
    XCTAssertEqual(controller.menuItem.state, .off)
    XCTAssertNotNil(presentedError)
  }

  func testApprovalRequiredRequestsEnableAndRemainsUncheckedUntilApproved() {
    let manager = StubLoginItemManager(status: .requiresApproval)
    let controller = LoginItemMenuController(manager: manager) { _ in }

    controller.toggleLoginItem(controller.menuItem)

    XCTAssertEqual(manager.enableCount, 1)
    XCTAssertEqual(manager.disableCount, 0)
    XCTAssertEqual(controller.menuItem.state, .off)
  }
}

@available(macOS 26.0, *)
@MainActor
private final class StubLoginItemManager: LoginItemManaging {
  var status: LoginItemStatus
  var enableError: (any Error)?
  var disableError: (any Error)?
  private(set) var enableCount = 0
  private(set) var disableCount = 0

  init(status: LoginItemStatus) {
    self.status = status
  }

  func enable() throws {
    enableCount += 1
    if let enableError { throw enableError }
    if status != .requiresApproval { status = .enabled }
  }

  func disable() throws {
    disableCount += 1
    if let disableError { throw disableError }
    status = .disabled
  }
}

private enum TestError: Error {
  case denied
}
