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
    runElevated: @escaping ElevatedRunner = DaemonInstaller.runAppleScript
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
    let result = try await runElevated(Self.installCommand(
      daemonURL: bundledDaemonURL, userID: userID, digest: digest))
    guard result.status == 0 else {
      throw DaemonInstallerError.authorizationFailed(
        result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  func manage(_ command: ServiceCommand) async throws {
    guard isInstalled else { throw DaemonInstallerError.daemonNotInstalled }
    let digest = try await bundledDaemonDigest()
    let result = try await runElevated(Self.serviceCommand(
      daemonURL: bundledDaemonURL, command: command, digest: digest))
    guard result.status == 0 else {
      throw DaemonInstallerError.authorizationFailed(
        result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  static func installCommand(daemonURL: URL, userID: UInt32, digest: String) -> String {
    stagedCommand(
      daemonURL: daemonURL, arguments: "install --user \(userID)", digest: digest)
  }

  static func serviceCommand(
    daemonURL: URL, command: ServiceCommand, digest: String
  ) -> String {
    stagedCommand(daemonURL: daemonURL, arguments: command.rawValue, digest: digest)
  }

  private static func stagedCommand(
    daemonURL: URL, arguments: String, digest: String
  ) -> String {
    let source = shellQuote(daemonURL.path)
    return """
      stage=$(/usr/bin/mktemp -d /private/tmp/dopa-install.XXXXXX) || exit 1
      trap '/bin/rm -rf "$stage"' EXIT HUP INT TERM
      /bin/cp \(source) "$stage/dopa-daemon" || exit 1
      actual=$(/usr/bin/shasum -a 256 "$stage/dopa-daemon" | /usr/bin/awk '{print $1}')
      if [ "$actual" != "\(digest)" ]; then
        echo 'bundled dopa-daemon changed before installation' >&2
        exit 1
      fi
      /usr/bin/codesign --verify --strict "$stage/dopa-daemon" || exit 1
      /usr/sbin/chown 0:0 "$stage/dopa-daemon" || exit 1
      /bin/chmod 0755 "$stage/dopa-daemon" || exit 1
      "$stage/dopa-daemon" \(arguments)
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

  static let elevationScript = """
    on run argv
      do shell script (item 1 of argv) with administrator privileges
    end run
    """

  static func runAppleScript(_ command: String) async throws -> CommandResult {
    try await Task.detached {
      let process = Process()
      let errors = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      // The command is an argv value, never interpolated into AppleScript
      // source. shellQuote protects the bundled executable path from sh.
      process.arguments = ["-e", elevationScript, command]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errors
      try process.run()
      process.waitUntilExit()
      let data = errors.fileHandleForReading.readDataToEndOfFile()
      return CommandResult(
        status: process.terminationStatus,
        standardError: String(decoding: data, as: UTF8.self))
    }.value
  }
}
