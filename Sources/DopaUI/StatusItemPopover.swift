import AppKit

extension NSPopover {
  /// Native symbol alignment insets change NSStatusBarButton's height. Its
  /// window's content area stays fixed and preserves the natural icon size.
  func show(relativeToStatusButton button: NSStatusBarButton) {
    guard let anchor = button.window?.contentView else { return }
    show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }
}
