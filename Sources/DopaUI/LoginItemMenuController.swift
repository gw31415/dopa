import AppKit
import ServiceManagement

@available(macOS 13.0, *)
@MainActor
protocol LoginItemManaging {
  var status: LoginItemStatus { get }
  func enable() throws
  func disable() throws
}

enum LoginItemStatus: Equatable {
  case disabled
  case enabled
  case requiresApproval
  case unavailable
}

@available(macOS 13.0, *)
@MainActor
struct SystemLoginItemManager: LoginItemManaging {
  private var service: SMAppService { .mainApp }

  var status: LoginItemStatus {
    Self.loginItemStatus(for: service.status)
  }

  static func loginItemStatus(for status: SMAppService.Status) -> LoginItemStatus {
    switch status {
    case .notRegistered: .disabled
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    // Service Management also reports notFound before it has ever seen the
    // main-app login item. Registration is the operation that makes it known,
    // so keep the menu actionable in this state.
    case .notFound: .disabled
    @unknown default: .unavailable
    }
  }

  func enable() throws {
    if service.status == .requiresApproval {
      SMAppService.openSystemSettingsLoginItems()
    } else {
      try service.register()
    }
  }

  func disable() throws {
    try service.unregister()
  }
}

@available(macOS 13.0, *)
@MainActor
final class LoginItemMenuController: NSObject, NSMenuDelegate {
  typealias ErrorPresenter = @MainActor (any Error) -> Void

  private let manager: any LoginItemManaging
  private let presentError: ErrorPresenter
  let menuItem: NSMenuItem

  init(
    manager: any LoginItemManaging = SystemLoginItemManager(),
    presentError: @escaping ErrorPresenter
  ) {
    self.manager = manager
    self.presentError = presentError
    menuItem = NSMenuItem(title: "ログイン時に起動", action: nil, keyEquivalent: "")
    super.init()
    menuItem.target = self
    menuItem.action = #selector(toggleLoginItem(_:))
    refresh()
  }

  func menuWillOpen(_ menu: NSMenu) {
    refresh()
  }

  func refresh() {
    switch manager.status {
    case .enabled:
      menuItem.state = .on
      menuItem.isEnabled = true
    case .disabled, .requiresApproval:
      // Approval is part of the effective state: until the user grants it in
      // System Settings, the application will not launch at login.
      menuItem.state = .off
      menuItem.isEnabled = true
    case .unavailable:
      menuItem.state = .off
      menuItem.isEnabled = false
    }
  }

  @objc func toggleLoginItem(_ sender: NSMenuItem) {
    do {
      if manager.status == .enabled {
        try manager.disable()
      } else {
        try manager.enable()
      }
    } catch {
      presentError(error)
    }
    // Service Management remains the source of truth, including when a
    // registration attempt is rejected or still requires user approval.
    refresh()
  }
}
