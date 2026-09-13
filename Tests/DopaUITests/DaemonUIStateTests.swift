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

    let starting = DaemonUIState.resolve(
      isInstalled: true, connectionState: .disconnected, isConfirmed: false,
      hasSessions: false, isStarting: true)
    XCTAssertEqual(starting, .starting)
    XCTAssertEqual(starting.symbol, "moon")
    XCTAssertEqual(starting.status, "dopa-daemon起動準備中")
    XCTAssertEqual(starting.clickAction, .normal)

    let installing = DaemonUIState.resolve(
      isInstalled: false, connectionState: .disconnected, isConfirmed: false,
      hasSessions: false, isStarting: true)
    XCTAssertEqual(installing, .starting)
    XCTAssertEqual(installing.symbol, "moon")
    XCTAssertEqual(installing.clickAction, .normal)

    let reconnecting = DaemonUIState.resolve(
      isInstalled: true, connectionState: .connecting, isConfirmed: false,
      hasSessions: false, isStarting: true)
    XCTAssertEqual(reconnecting, .starting)
    XCTAssertEqual(reconnecting.symbol, "moon")

    let checking = DaemonUIState.resolve(
      isInstalled: true, connectionState: .connecting, isConfirmed: false, hasSessions: false)
    XCTAssertEqual(checking, .checking)
    XCTAssertEqual(checking.clickAction, .normal)

    let idle = DaemonUIState.resolve(
      isInstalled: true, connectionState: .connected, isConfirmed: true,
      hasSessions: false, isStarting: true)
    XCTAssertEqual(idle.symbol, "moon.fill")
    XCTAssertEqual(idle.clickAction, .normal)

    let active = DaemonUIState.resolve(
      isInstalled: true, connectionState: .connected, isConfirmed: true, hasSessions: true)
    XCTAssertEqual(active.symbol, "cup.and.saucer.fill")
    XCTAssertEqual(active.clickAction, .normal)
  }
}
