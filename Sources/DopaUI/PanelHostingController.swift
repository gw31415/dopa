import AppKit
import SwiftUI

/// The popover owns a fixed content size while open. SwiftUI lays out inside
/// that size rather than updating NSPopover on every control-state change.
@available(macOS 26.0, *)
final class PanelHostingController<Content: View>: NSHostingController<Content> {
  override init(rootView: Content) {
    super.init(rootView: rootView)
    sizingOptions = []
  }

  @MainActor required dynamic init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  @discardableResult
  func prepareSize() -> NSSize {
    let size = sizeThatFits(in: NSSize(width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude))
    preferredContentSize = size
    view.setFrameSize(size)
    return size
  }
}
