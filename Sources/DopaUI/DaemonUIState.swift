import DopaUIModel

@available(macOS 14.0, *)
enum DaemonUIState: Equatable {
  enum ClickAction: Equatable { case install, start, normal }

  case notInstalled
  case stopped
  case installing
  case starting
  case checking
  case idle
  case active

  static func resolve(
    isInstalled: Bool,
    connectionState: AppModel.ConnectionState,
    isConfirmed: Bool,
    hasSessions: Bool,
    isStarting: Bool = false
  ) -> Self {
    if isStarting, connectionState != .connected {
      return isInstalled ? .starting : .installing
    }
    guard isInstalled else { return .notInstalled }
    switch connectionState {
    case .disconnected: return .stopped
    case .connecting: return .checking
    case .connected:
      guard isConfirmed else { return .checking }
      return hasSessions ? .active : .idle
    }
  }

  var symbol: String {
    switch self {
    case .notInstalled: "moon"
    case .installing: "moon"
    case .starting: "progress.indicator"
    case .stopped, .checking: "exclamationmark.triangle"
    case .idle: "moon.fill"
    case .active: "cup.and.saucer.fill"
    }
  }

  var status: String? {
    switch self {
    case .notInstalled: "dopa-daemon未インストール"
    case .stopped: "dopa-daemon停止中"
    case .installing: "dopa-daemonインストール中"
    case .starting: "dopa-daemonとの接続を確認中"
    default: nil
    }
  }

  var showsActivityIndicator: Bool { self == .starting }

  var clickAction: ClickAction {
    switch self {
    case .notInstalled: .install
    case .stopped: .start
    case .installing, .starting: .normal
    default: .normal
    }
  }
}
