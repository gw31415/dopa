import AppKit
@testable import DopaUI
import DopaUIModel
import XCTest

/// The status popover is built on first presentation, not at launch,
/// and the built instance is kept, so later presentations reuse the same
/// views (draft, focus, tab order, scroll position, error display).
@available(macOS 26.0, *)
@MainActor
final class PopoverLazyTests: XCTestCase {
  func testPopoverBuildsLazilyAndIsRetained() {
    let delegate = DopaAppDelegate()
    XCTAssertFalse(delegate.hasPopover)
    let model = AppModel()
    let first = delegate.ensurePopover(for: model)
    XCTAssertTrue(delegate.hasPopover)
    XCTAssertTrue(first.behavior == .transient)
    XCTAssertFalse(first.animates)
    XCTAssertTrue(first.delegate === delegate)
    XCTAssertNotNil(first.contentViewController)
    XCTAssertTrue(delegate.ensurePopover(for: model) === first)
  }
}
