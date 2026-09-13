import Foundation
import Darwin
import CryptoKit

struct DaemonInstallationLayout: Sendable {
  var plistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/dev.dopa.daemon.plist")
  var executableURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/dev.dopa.daemon")
  var ownerUID: uid_t = 0
  var ownerGID: gid_t = 0
}

enum DaemonInstallerError: Error, LocalizedError, Equatable {
  case bundledDaemonUnavailable
  case daemonNotInstalled
  case authorizationFailed(String)

  var errorDescription: String? {
    switch self {
    case .bundledDaemonUnavailable:
      return "Appに同梱されたdopa-daemonを確認できません。Dopa.appを再インストールしてください。"
    case .daemonNotInstalled:
      return "dopa-daemonがインストールされていません。"
    case .authorizationFailed(let detail):
      return detail.isEmpty ? "dopa-daemonをインストールできませんでした。" : detail
    }
  }
}

struct DaemonInstaller: Sendable {
  enum ServiceCommand: String, Sendable { case start, stop, restart }

  struct CommandResult: Sendable, Equatable {
    var status: Int32
    var standardError: String
  }

  typealias ElevatedRunner = @Sendable (String) async throws -> CommandResult

  private let layout: DaemonInstallationLayout
  private let bundledDaemonURL: URL
  private let userID: UInt32
  private let runElevated: ElevatedRunner

  init(
    layout: DaemonInstallationLayout = DaemonInstallationLayout(),
    bundleURL: URL = Bundle.main.bundleURL,
    userID: UInt32 = geteuid(),
    runElevated: @escaping ElevatedRunner = PAMAuthorizationRunner.run
  ) {
    self.layout = layout
    bundledDaemonURL = bundleURL.appendingPathComponent("Contents/Helpers/dopa-daemon")
    self.userID = userID
    self.runElevated = runElevated
  }

  var isInstalled: Bool {
    Self.isSecureRegularFile(
      layout.plistURL, ownerUID: layout.ownerUID, ownerGID: layout.ownerGID)
      && Self.isSecureRegularFile(
        layout.executableURL, ownerUID: layout.ownerUID, ownerGID: layout.ownerGID)
      && FileManager.default.isExecutableFile(atPath: layout.executableURL.path)
  }

  func install() async throws {
    let digest = try await bundledDaemonDigest()
    try Task.checkCancellation()
    let result = try await runElevated(Self.installCommand(
      daemonURL: bundledDaemonURL, userID: userID, digest: digest))
    guard result.status == 0 else {
      throw DaemonInstallerError.authorizationFailed(
        result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  func manage(_ command: ServiceCommand) async throws {
    guard isInstalled else { throw DaemonInstallerError.daemonNotInstalled }
    try Task.checkCancellation()
    let result = try await runElevated(Self.serviceCommand(
      daemonURL: layout.executableURL, command: command))
    guard result.status == 0 else {
      throw DaemonInstallerError.authorizationFailed(
        result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  static func installCommand(daemonURL: URL, userID: UInt32, digest: String) -> String {
    verifiedBundledCommand(
      daemonURL: daemonURL, arguments: "install --user \(userID)", digest: digest)
  }

  static func serviceCommand(
    daemonURL: URL, command: ServiceCommand
  ) -> String {
    "exec \(shellQuote(daemonURL.path)) \(command.rawValue)"
  }

  private static func verifiedBundledCommand(
    daemonURL: URL, arguments: String, digest: String
  ) -> String {
    let source = shellQuote(daemonURL.path)
    return """
      source=\(source)
      if [ -L "$source" ] || [ ! -f "$source" ] || [ ! -x "$source" ]; then
        echo 'bundled dopa-daemon is not a regular executable' >&2
        exit 1
      fi
      actual=$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{print $1}')
      if [ "$actual" != "\(digest)" ]; then
        echo 'bundled dopa-daemon changed before installation' >&2
        exit 1
      fi
      /usr/bin/codesign --verify --strict "$source" || exit 1
      exec "$source" \(arguments)
      """
  }

  private func bundledDaemonDigest() async throws -> String {
    guard Self.isRegularFile(bundledDaemonURL),
      FileManager.default.isExecutableFile(atPath: bundledDaemonURL.path)
    else { throw DaemonInstallerError.bundledDaemonUnavailable }
    return try await Task.detached { [bundledDaemonURL] in
      SHA256.hash(data: try Data(contentsOf: bundledDaemonURL))
        .map { String(format: "%02x", $0) }.joined()
    }.value
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    var information = Darwin.stat()
    let inspected = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      return lstat(path, &information) == 0
    }
    return inspected && (information.st_mode & S_IFMT) == S_IFREG
  }

  private static func isSecureRegularFile(
    _ url: URL, ownerUID: uid_t, ownerGID: gid_t
  ) -> Bool {
    var information = Darwin.stat()
    let inspected = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      return lstat(path, &information) == 0
    }
    return inspected && (information.st_mode & S_IFMT) == S_IFREG
      && information.st_uid == ownerUID && information.st_gid == ownerGID
      && (information.st_mode & 0o022) == 0
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

}
