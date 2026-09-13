@testable import DopaUI
import DopaUIModel
import XCTest

@available(macOS 14.0, *)
final class DaemonUIStateTests: XCTestCase {
  func testInstallationAndConnectionStatesChooseDistinctIconsAndActions() {
    let missing = DaemonUIState.resolve(
      isInstalled: false, connectionState: .connected, isConfirmed: true, hasSessions: true)
    XCTAssertEqual(missing, .notInstalled)
    XCTAssertEqual(missing.symbol, "moon")
    XCTAssertEqual(missing.clickAction, .install)

    let stopped = DaemonUIState.resolve(
      isInstalled: true, connectionState: .disconnected, isConfirmed: false, hasSessions: false)
    XCTAssertEqual(stopped, .stopped)
    XCTAssertEqual(stopped.symbol, "exclamationmark.triangle")
    XCTAssertEqual(stopped.clickAction, .start)

    let checking = DaemonUIState.resolve(
      isInstalled: true, connectionState: .connecting, isConfirmed: false, hasSessions: false)
    XCTAssertEqual(checking, .checking)
    XCTAssertEqual(checking.clickAction, .normal)

    let idle = DaemonUIState.resolve(
      isInstalled: true, connectionState: .connected, isConfirmed: true, hasSessions: false)
    XCTAssertEqual(idle.symbol, "moon.fill")
    XCTAssertEqual(idle.clickAction, .normal)

    let active = DaemonUIState.resolve(
      isInstalled: true, connectionState: .connected, isConfirmed: true, hasSessions: true)
    XCTAssertEqual(active.symbol, "cup.and.saucer.fill")
    XCTAssertEqual(active.clickAction, .normal)
  }
}
