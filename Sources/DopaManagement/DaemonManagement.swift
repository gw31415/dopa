import CoreFoundation
import Darwin
import DopaClient
import DopaProtocol
import Foundation

public enum DaemonManagementError: Error, CustomStringConvertible, Sendable {
  case invalidConfiguration(String)
  case unsafePath(String)
  case commandFailed(String)
  case serviceUnavailable(String)
  case rollbackFailed(String)
  case permissionDenied(String)
  case userNotFound(String)

  public var description: String {
    switch self {
    case .invalidConfiguration(let message): return message
    case .unsafePath(let message): return message
    case .commandFailed(let message): return message
    case .serviceUnavailable(let message): return message
    case .rollbackFailed(let message): return message
    case .permissionDenied(let message): return message
    case .userNotFound(let message): return message
    }
  }
}

public struct CommandResult: Sendable, Equatable {
  public let status: Int32
  public let stdout: String
  public let stderr: String

  public init(status: Int32, stdout: String = "", stderr: String = "") {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }

  public var succeeded: Bool { status == 0 }
}

public protocol CommandRunner: Sendable {
  func run(executable: String, arguments: [String]) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunner {
  public init() {}

  public func run(executable: String, arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    // Drain command output through files. Waiting on a process while its
    // stdout/stderr pipes are full can deadlock an installer on a large
    // launchctl diagnostic.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dopa-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
    let outputURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    let error = try FileHandle(forWritingTo: errorURL)
    process.standardOutput = output
    process.standardError = error
    defer {
      try? output.close()
      try? error.close()
      try? FileManager.default.removeItem(at: directory)
    }
    do {
      try process.run()
    } catch {
      throw DaemonManagementError.commandFailed(
        "cannot start \(executable): \(error.localizedDescription)")
    }
    process.waitUntilExit()
    try output.close()
    try error.close()
    let stdout = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
    let stderr = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
    return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
  }
}

public struct DaemonLayout: Equatable, Sendable {
  public let serviceLabel: String
  public let plistPath: String
  public let executablePath: String
  public let configPath: String
  public let statePath: String
  public let socketPath: String
  public let expectedOwnerUID: uid_t
  public let expectedGroupGID: gid_t

  public init(
    serviceLabel: String = "dev.amas.dopa.daemon",
    plistPath: String = "/Library/LaunchDaemons/dev.amas.dopa.daemon.plist",
    executablePath: String = "/Library/PrivilegedHelperTools/dev.amas.dopa.daemon",
    configPath: String = "/var/db/dopa/config.json",
    statePath: String = "/var/db/dopa",
    socketPath: String = "/var/run/dopa/control.sock",
    expectedOwnerUID: uid_t = 0,
    expectedGroupGID: gid_t = 0
  ) {
    self.serviceLabel = serviceLabel
    self.plistPath = plistPath
    self.executablePath = executablePath
    self.configPath = configPath
    self.statePath = statePath
    self.socketPath = socketPath
    self.expectedOwnerUID = expectedOwnerUID
    self.expectedGroupGID = expectedGroupGID
  }

  public static let system = DaemonLayout()
  public static let legacySystem = DaemonLayout(
    serviceLabel: "dev.dopa.daemon",
    plistPath: "/Library/LaunchDaemons/dev.dopa.daemon.plist",
    executablePath: "/Library/PrivilegedHelperTools/dev.dopa.daemon")

  public static func temporary(
    rootDirectory: URL,
    ownerUID: uid_t = geteuid(),
    groupGID: gid_t = getegid()
  ) -> DaemonLayout {
    let root = rootDirectory.path
    return DaemonLayout(
      serviceLabel: "dev.amas.dopa.daemon.test",
      plistPath: root + "/LaunchDaemons/dev.amas.dopa.daemon.plist",
      executablePath: root + "/PrivilegedHelperTools/dev.amas.dopa.daemon",
      configPath: root + "/state/config.json",
      statePath: root + "/state",
      socketPath: root + "/run/control.sock",
      expectedOwnerUID: ownerUID,
      expectedGroupGID: groupGID)
  }

  public var serviceTarget: String { "system/\(serviceLabel)" }

  public var socketEntryPath: String { socketPath }
}

public struct DaemonConfiguration: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let allowedUID: uid_t

  public init(allowedUID: uid_t, version: Int = currentVersion) {
    self.version = version
    self.allowedUID = allowedUID
  }

  public init(data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["version", "allowedUID"],
      let version = Self.strictInteger(object["version"]),
      let uid = Self.strictInteger(object["allowedUID"])
    else {
      throw DaemonManagementError.invalidConfiguration("invalid Dopa daemon configuration")
    }
    guard version == Self.currentVersion, uid >= 0, UInt64(uid) <= UInt64(uid_t.max) else {
      throw DaemonManagementError.invalidConfiguration(
        "unsupported or invalid Dopa daemon configuration")
    }
    self.init(allowedUID: uid_t(uid), version: Int(version))
  }

  public func data() throws -> Data {
    let object: [String: Any] = ["version": version, "allowedUID": Int64(allowedUID)]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw DaemonManagementError.invalidConfiguration("cannot encode Dopa daemon configuration")
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  public static func load(from path: String) throws -> DaemonConfiguration {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    } catch {
      throw DaemonManagementError.invalidConfiguration(
        "cannot read daemon configuration at \(path): \(error.localizedDescription)")
    }
    return try DaemonConfiguration(data: data)
  }

  /// Loads the configuration after checking the pathname and ownership used
  /// by the root daemon. This check deliberately rejects symlinks so a
  /// writable user path can never become daemon input.
  public static func loadSecure(
    from path: String, ownerUID: uid_t = 0, groupGID: gid_t? = nil, mode: mode_t = 0o600
  ) throws -> DaemonConfiguration {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      throw DaemonManagementError.invalidConfiguration(
        "cannot inspect daemon configuration at \(path): \(String(cString: strerror(errno)))")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      info.st_uid == ownerUID, groupGID.map({ info.st_gid == $0 }) ?? true,
      info.st_mode & 0o7777 == mode
    else {
      throw DaemonManagementError.unsafePath("unsafe daemon configuration: \(path)")
    }
    return try load(from: path)
  }

  private static func strictInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let type = String(cString: number.objCType)
    guard ["c", "i", "s", "l", "q", "C", "I", "S", "L", "Q"].contains(type) else {
      return nil
    }
    let value = number.int64Value
    guard number.doubleValue.isFinite, Double(value) == number.doubleValue else { return nil }
    return value
  }
}

public enum DaemonUserResolver {
  public static func resolve(_ value: String) throws -> uid_t {
    if let numeric = parseNumericUID(value) {
      guard getpwuid(numeric) != nil else {
        throw DaemonManagementError.userNotFound("no account exists for UID \(numeric)")
      }
      return numeric
    }
    guard !value.isEmpty, value.utf8.count <= 255 else {
      throw DaemonManagementError.userNotFound("invalid account name")
    }
    let uid: uid_t? = value.withCString { name in
      guard let entry = getpwnam(name) else { return nil }
      return entry.pointee.pw_uid
    }
    guard let uid else {
      throw DaemonManagementError.userNotFound("no account exists for \(value)")
    }
    return uid
  }

  public static func resolveInstallUser(
    explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> uid_t {
    if let explicit { return try resolve(explicit) }
    if let sudoUID = environment["SUDO_UID"], !sudoUID.isEmpty {
      return try resolve(sudoUID)
    }
    if let sudoUser = environment["SUDO_USER"], !sudoUser.isEmpty {
      return try resolve(sudoUser)
    }
    throw DaemonManagementError.userNotFound(
      "cannot determine the allowed user; use sudo dopa-daemon install --user NAME")
  }

  private static func parseNumericUID(_ value: String) -> uid_t? {
    guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    guard let number = UInt64(value), number <= UInt64(uid_t.max) else { return nil }
    return uid_t(number)
  }
}

public typealias ShutdownRequester = (_ socketPath: String) throws -> Void
public typealias ReadinessChecker = (_ socketPath: String) -> Bool

public final class DaemonManager: @unchecked Sendable {
  private struct FileSnapshot {
    let path: String
    let data: Data?
    let mode: mode_t
    let uid: uid_t
    let gid: gid_t

    var exists: Bool { data != nil }
  }

  private let layout: DaemonLayout
  private let commandRunner: any CommandRunner
  private let shutdownRequester: ShutdownRequester?
  private let readinessChecker: ReadinessChecker?
  private let requireRoot: Bool

  public init(
    layout: DaemonLayout = .system,
    commandRunner: any CommandRunner = ProcessCommandRunner(),
    shutdownRequester: ShutdownRequester? = nil,
    readinessChecker: ReadinessChecker? = nil,
    requireRoot: Bool = true
  ) {
    self.layout = layout
    self.commandRunner = commandRunner
    self.shutdownRequester = shutdownRequester
    self.readinessChecker = readinessChecker
    self.requireRoot = requireRoot
  }

  public var daemonLayout: DaemonLayout { layout }

  public func install(
    executableURL: URL,
    user: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    try checkRoot()
    let lock = try acquireManagementLock()
    defer { close(lock) }
    let stagedExecutable = try stageExecutable(at: executableURL.path)
    defer { close(stagedExecutable) }
    try installLocked(
      stagedExecutableFD: stagedExecutable, user: user, environment: environment)
  }

  private func installLocked(
    stagedExecutableFD: Int32,
    user: String?,
    environment: [String: String]
  ) throws {
    let existing = try snapshotManagedFiles()
    let hasExisting = existing.contains { $0.exists }
    if hasExisting && !existing.allSatisfy({ $0.exists }) {
      throw DaemonManagementError.invalidConfiguration(
        "daemon installation is incomplete; refusing to update managed files")
    }
    let oldConfiguration = try loadExistingConfiguration(hasExisting: hasExisting)
    let requestedUID: uid_t
    if let oldConfiguration {
      if let user {
        let explicitUID = try DaemonUserResolver.resolve(user)
        guard explicitUID == oldConfiguration.allowedUID else {
          throw DaemonManagementError.invalidConfiguration(
            "allowed user is already configured; run dopa-daemon uninstall before changing it")
        }
      }
      // An update without --user intentionally keeps the existing account;
      // SUDO_UID must never silently change a live installation.
      requestedUID = oldConfiguration.allowedUID
    } else {
      requestedUID = try DaemonUserResolver.resolveInstallUser(
        explicit: user, environment: environment)
    }

    if hasExisting {
      try prepareAndBootoutExistingService()
    }
    // A legacy guardian can still hold the state election lock even when no
    // managed launchd files exist. Refuse to install beside it rather than
    // starting a second daemon that cannot own the state directory.
    try preflightStateLock()

    var bootstrapAttempted = false
    do {
      try writeManagedFiles(
        sourceFD: stagedExecutableFD,
        configuration: DaemonConfiguration(allowedUID: requestedUID))
      bootstrapAttempted = true
      try bootstrap()
      try waitUntilReady()
    } catch {
      let originalError = error
      do {
        try rollback(
          to: existing, serviceWasInstalled: hasExisting, bootstrapAttempted: bootstrapAttempted)
      } catch {
        throw DaemonManagementError.rollbackFailed(
          "install failed (\(originalError)); rollback failed (\(error))")
      }
      throw originalError
    }
  }

  /// Replaces an installation that used an older launchd identity while
  /// preserving its configured user. The legacy service is shut down through
  /// its own label before the current service is installed, so both identities
  /// can never own the shared runtime socket at the same time.
  public func installReplacingLegacy(
    executableURL: URL,
    user: String? = nil,
    legacyLayout: DaemonLayout = .legacySystem,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    try checkRoot()
    let legacyManager = DaemonManager(
      layout: legacyLayout,
      commandRunner: commandRunner,
      shutdownRequester: shutdownRequester,
      readinessChecker: readinessChecker,
      requireRoot: requireRoot)
    // Hold every participating installation's lock for the complete identity
    // transition. Public install/uninstall calls use these same files, so no
    // lifecycle command can enter between removal of the legacy identity and
    // publication (or rollback) of the current one.
    let locks = try acquireManagementLocks(with: legacyManager)
    defer { for lock in locks.reversed() { close(lock) } }

    // Read and durably stage every candidate byte before stopping a working
    // service. The returned descriptor refers to an unlinked, read-only inode,
    // so later source-path replacement or in-place mutation cannot affect the
    // executable that is eventually published.
    let stagedExecutable = try stageExecutable(at: executableURL.path)
    defer { close(stagedExecutable) }

    guard layout != legacyLayout, !(try hasIdentityFiles()) else {
      try installLocked(
        stagedExecutableFD: stagedExecutable, user: user, environment: environment)
      return
    }

    guard try legacyManager.hasIdentityFiles() else {
      try installLocked(
        stagedExecutableFD: stagedExecutable, user: user, environment: environment)
      return
    }

    let legacyInstallation = try legacyManager.snapshotManagedFiles()
    guard legacyInstallation.allSatisfy(\.exists) else {
      throw DaemonManagementError.invalidConfiguration(
        "legacy daemon installation is incomplete; refusing to migrate it")
    }
    guard
      let legacyConfigSnapshot = legacyInstallation.first(where: {
        $0.path == legacyLayout.configPath
      }),
      legacyConfigSnapshot.mode == 0o600,
      let legacyConfigData = legacyConfigSnapshot.data
    else {
      throw DaemonManagementError.unsafePath(
        "unsafe daemon configuration: \(legacyLayout.configPath)")
    }
    let legacyConfiguration = try DaemonConfiguration(data: legacyConfigData)
    if let user {
      let requestedUID = try DaemonUserResolver.resolve(user)
      guard requestedUID == legacyConfiguration.allowedUID else {
        throw DaemonManagementError.invalidConfiguration(
          "allowed user is already configured; uninstall before changing it")
      }
    }

    let preservedUser = String(legacyConfiguration.allowedUID)
    try legacyManager.uninstallLocked(waitForRestoredService: true)
    do {
      try installLocked(
        stagedExecutableFD: stagedExecutable,
        user: preservedUser,
        environment: environment)
    } catch {
      let migrationError = error
      // A failed rollback can mean the replacement service is still live. In
      // that state overwriting its files with the legacy identity is unsafe;
      // retain the recovery artifacts and propagate the more useful error.
      if let managementError = migrationError as? DaemonManagementError,
        case .rollbackFailed = managementError
      {
        throw migrationError
      }
      do {
        try legacyManager.restore(snapshots: legacyInstallation)
        try legacyManager.bootstrap()
        try legacyManager.waitUntilReady()
      } catch {
        throw DaemonManagementError.rollbackFailed(
          "identity migration failed (\(migrationError)); legacy service restoration failed (\(error))"
        )
      }
      throw migrationError
    }
  }

  public func uninstall() throws {
    try checkRoot()
    let lock = try acquireManagementLock()
    defer { close(lock) }
    try uninstallLocked()
  }

  private func uninstallLocked(waitForRestoredService: Bool = false) throws {
    let existing = try snapshotManagedFiles()
    guard existing.contains(where: { $0.exists }) else { return }

    // Refuse an incomplete or unsafe installation before stopping anything.
    guard existing.allSatisfy({ $0.exists }) else {
      throw DaemonManagementError.invalidConfiguration(
        "daemon installation is incomplete; refusing to remove managed files")
    }
    _ = try loadExistingConfiguration(hasExisting: true)
    try prepareAndBootoutExistingService()

    do {
      for snapshot in existing { try removeManagedFile(snapshot.path) }
    } catch {
      // The service is already stopped. Restore the files and try to make the
      // previous installation usable again, preserving every original byte.
      do {
        try restore(snapshots: existing)
        try bootstrap()
        if waitForRestoredService { try waitUntilReady() }
      } catch {
        throw DaemonManagementError.rollbackFailed(
          "uninstall failed (\(error)); previous installation could not be restored")
      }
      throw error
    }
  }

  /// Starts an already-installed daemon through launchd.
  ///
  /// The managed files are checked while holding the same lock used by
  /// install/uninstall. A successful launchd operation is not enough to call
  /// this command successful: the daemon must answer a status request and
  /// report a healthy idle or active phase.
  public func start() throws {
    try checkRoot()
    let lock = try acquireManagementLock()
    defer { close(lock) }
    _ = try validateExistingInstallation()
    try startExistingService()
    try waitUntilReady()
  }

  /// Stops an already-installed daemon after it has confirmed session
  /// cleanup and restoration. If the service is currently not reachable,
  /// prepareAndBootoutExistingService starts that exact installation once so
  /// the daemon can recover its journal before it is booted out.
  public func stop() throws {
    try checkRoot()
    let lock = try acquireManagementLock()
    defer { close(lock) }
    _ = try validateExistingInstallation()
    try prepareAndBootoutExistingService()
  }

  /// Performs a safe stop followed by a fresh launchd bootstrap and readiness
  /// check, under one management lock so another lifecycle command cannot
  /// interleave between the two phases.
  public func restart() throws {
    try checkRoot()
    let lock = try acquireManagementLock()
    defer { close(lock) }
    _ = try validateExistingInstallation()
    try prepareAndBootoutExistingService()
    try bootstrap()
    try waitUntilReady()
  }

  private func checkRoot() throws {
    guard !requireRoot || geteuid() == 0 else {
      throw DaemonManagementError.permissionDenied("root is required; run with sudo")
    }
  }

  private func acquireManagementLocks(with other: DaemonManager) throws -> [Int32] {
    let participants = [self, other]
      .map { manager in
        (
          path: URL(
            fileURLWithPath: manager.normalizeKnownSystemAlias(manager.layout.statePath)
          ).standardizedFileURL.path,
          manager: manager
        )
      }
      .sorted { $0.path < $1.path }

    var locks: [Int32] = []
    var previousPath: String?
    do {
      for participant in participants where participant.path != previousPath {
        locks.append(try participant.manager.acquireManagementLock())
        previousPath = participant.path
      }
      return locks
    } catch {
      for lock in locks.reversed() { close(lock) }
      throw error
    }
  }

  private func acquireManagementLock() throws -> Int32 {
    try ensureDirectory(layout.statePath, mode: 0o700)
    let directory = try openDirectory(layout.statePath)
    defer { close(directory) }
    let fd = openat(
      directory, "management.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw DaemonManagementError.commandFailed(
        "open management lock: \(String(cString: strerror(errno)))")
    }
    var info = stat()
    guard fstat(fd, &info) == 0,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1,
      info.st_uid == layout.expectedOwnerUID,
      info.st_mode & 0o077 == 0,
      fchmod(fd, 0o600) == 0,
      fchown(fd, layout.expectedOwnerUID, layout.expectedGroupGID) == 0
    else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw DaemonManagementError.unsafePath("set management lock ownership: \(message)")
    }
    guard flock(fd, LOCK_EX) == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw DaemonManagementError.commandFailed("lock daemon management: \(message)")
    }
    return fd
  }

  private func preflightStateLock() throws {
    let directory = try openDirectory(layout.statePath)
    defer { close(directory) }
    let fd = openat(directory, "lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return }
      throw DaemonManagementError.unsafePath(
        "cannot inspect state lock: \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_uid == layout.expectedOwnerUID,
      info.st_gid == layout.expectedGroupGID, info.st_mode & 0o077 == 0
    else {
      throw DaemonManagementError.unsafePath("unsafe state lock")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK || errno == EAGAIN {
        throw DaemonManagementError.serviceUnavailable(
          "an existing Dopa session still owns the state; stop it before installation")
      }
      throw DaemonManagementError.commandFailed(
        "check state lock: \(String(cString: strerror(errno)))")
    }
  }

  private func loadExistingConfiguration(hasExisting: Bool) throws -> DaemonConfiguration? {
    let config = try snapshot(layout.configPath)
    guard config.exists else {
      if hasExisting { throw DaemonManagementError.invalidConfiguration("daemon config is missing") }
      return nil
    }
    guard let data = config.data else { return nil }
    return try DaemonConfiguration(data: data)
  }

  private func validateExistingInstallation() throws -> [FileSnapshot] {
    let existing = try snapshotManagedFiles()
    guard existing.allSatisfy(\.exists) else {
      if existing.contains(where: { $0.exists }) {
        throw DaemonManagementError.invalidConfiguration(
          "daemon installation is incomplete; run dopa-daemon install")
      }
      throw DaemonManagementError.invalidConfiguration(
        "dopa-daemon is not installed; run dopa-daemon install")
    }

    let expectedModes: [String: mode_t] = [
      layout.executablePath: 0o755,
      layout.plistPath: 0o644,
      layout.configPath: 0o600,
    ]
    for snapshot in existing {
      guard let expectedMode = expectedModes[snapshot.path], snapshot.mode == expectedMode else {
        throw DaemonManagementError.unsafePath(
          "managed file has unsafe mode: \(snapshot.path)")
      }
    }
    _ = try DaemonConfiguration.loadSecure(
      from: layout.configPath,
      ownerUID: layout.expectedOwnerUID,
      groupGID: layout.expectedGroupGID,
      mode: 0o600)
    return existing
  }

  private func snapshotManagedFiles() throws -> [FileSnapshot] {
    try [
      snapshot(layout.plistPath), snapshot(layout.executablePath), snapshot(layout.configPath),
    ]
  }

  private func snapshotIdentityFiles() throws -> [FileSnapshot] {
    try [snapshot(layout.plistPath), snapshot(layout.executablePath)]
  }

  private func hasIdentityFiles() throws -> Bool {
    try snapshotIdentityFiles().contains(where: \.exists)
  }

  private func snapshot(_ path: String) throws -> FileSnapshot {
    var info = stat()
    if lstat(path, &info) != 0 {
      if errno == ENOENT { return FileSnapshot(path: path, data: nil, mode: 0, uid: 0, gid: 0) }
      throw DaemonManagementError.unsafePath(
        "cannot inspect managed path \(path): \(String(cString: strerror(errno)))")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      throw DaemonManagementError.unsafePath("managed path is not a regular file: \(path)")
    }
    guard info.st_uid == layout.expectedOwnerUID,
      info.st_gid == layout.expectedGroupGID,
      info.st_mode & 0o022 == 0
    else {
      throw DaemonManagementError.unsafePath("managed path has unsafe ownership or mode: \(path)")
    }
    do {
      return FileSnapshot(
        path: path,
        data: try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
        mode: info.st_mode & 0o7777,
        uid: info.st_uid,
        gid: info.st_gid)
    } catch {
      throw DaemonManagementError.unsafePath(
        "cannot read managed path \(path): \(error.localizedDescription)")
    }
  }

  private func openExecutable(at path: String) throws -> Int32 {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      throw DaemonManagementError.unsafePath(
        "cannot inspect daemon executable: \(String(cString: strerror(errno)))")
    }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      close(fd)
      throw DaemonManagementError.unsafePath(
        "cannot inspect daemon executable: \(String(cString: strerror(errno)))")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      close(fd)
      throw DaemonManagementError.unsafePath("daemon executable must be a regular file")
    }
    guard info.st_mode & 0o111 != 0 else {
      close(fd)
      throw DaemonManagementError.unsafePath("daemon executable is not executable")
    }
    guard info.st_size > 0 else {
      close(fd)
      throw DaemonManagementError.unsafePath("daemon executable is empty")
    }
    return fd
  }

  private func stageExecutable(at path: String) throws -> Int32 {
    let sourceFD = try openExecutable(at: path)
    defer { close(sourceFD) }

    var sourceBefore = stat()
    guard fstat(sourceFD, &sourceBefore) == 0 else {
      throw DaemonManagementError.unsafePath(
        "cannot inspect daemon executable: \(String(cString: strerror(errno)))")
    }

    let directory = try openDirectory(layout.statePath)
    defer { close(directory) }
    let temporaryName = ".candidate-\(UUID().uuidString)"
    var stagedLinked = true
    var writer = openat(
      directory, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600)
    guard writer >= 0 else {
      throw DaemonManagementError.commandFailed(
        "create staged daemon executable: \(String(cString: strerror(errno)))")
    }
    defer {
      if writer >= 0 { close(writer) }
      if stagedLinked { _ = unlinkat(directory, temporaryName, 0) }
    }

    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var copied: off_t = 0
    while true {
      let count = Darwin.read(sourceFD, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw DaemonManagementError.unsafePath(
          "cannot read daemon executable: \(String(cString: strerror(errno)))")
      }
      if count == 0 { break }
      copied += off_t(count)

      var written = 0
      while written < count {
        let amount = buffer.withUnsafeBytes { rawBuffer in
          Darwin.write(
            writer,
            rawBuffer.baseAddress!.advanced(by: written),
            count - written)
        }
        if amount < 0 {
          if errno == EINTR { continue }
          throw DaemonManagementError.commandFailed(
            "write staged daemon executable: \(String(cString: strerror(errno)))")
        }
        guard amount > 0 else {
          throw DaemonManagementError.commandFailed(
            "zero-length staged daemon executable write")
        }
        written += amount
      }
    }

    var sourceAfter = stat()
    guard fstat(sourceFD, &sourceAfter) == 0 else {
      throw DaemonManagementError.unsafePath(
        "cannot inspect daemon executable after staging: \(String(cString: strerror(errno)))")
    }
    guard copied > 0,
      copied == sourceBefore.st_size,
      sourceBefore.st_dev == sourceAfter.st_dev,
      sourceBefore.st_ino == sourceAfter.st_ino,
      sourceBefore.st_size == sourceAfter.st_size,
      sourceBefore.st_mtimespec.tv_sec == sourceAfter.st_mtimespec.tv_sec,
      sourceBefore.st_mtimespec.tv_nsec == sourceAfter.st_mtimespec.tv_nsec,
      sourceBefore.st_ctimespec.tv_sec == sourceAfter.st_ctimespec.tv_sec,
      sourceBefore.st_ctimespec.tv_nsec == sourceAfter.st_ctimespec.tv_nsec
    else {
      throw DaemonManagementError.unsafePath(
        "daemon executable changed while it was being staged")
    }

    guard fchmod(writer, 0o400) == 0 else {
      throw DaemonManagementError.commandFailed(
        "secure staged daemon executable: \(String(cString: strerror(errno)))")
    }
    guard fchown(writer, layout.expectedOwnerUID, layout.expectedGroupGID) == 0 else {
      throw DaemonManagementError.commandFailed(
        "set staged daemon executable ownership: \(String(cString: strerror(errno)))")
    }
    guard fsync(writer) == 0 else {
      throw DaemonManagementError.commandFailed(
        "flush staged daemon executable: \(String(cString: strerror(errno)))")
    }

    var stagedInfo = stat()
    guard fstat(writer, &stagedInfo) == 0 else {
      throw DaemonManagementError.commandFailed(
        "inspect staged daemon executable: \(String(cString: strerror(errno)))")
    }
    close(writer)
    writer = -1

    let stagedFD = openat(directory, temporaryName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard stagedFD >= 0 else {
      throw DaemonManagementError.commandFailed(
        "open staged daemon executable: \(String(cString: strerror(errno)))")
    }
    var reopenedInfo = stat()
    guard fstat(stagedFD, &reopenedInfo) == 0,
      reopenedInfo.st_dev == stagedInfo.st_dev,
      reopenedInfo.st_ino == stagedInfo.st_ino,
      reopenedInfo.st_mode & S_IFMT == S_IFREG,
      reopenedInfo.st_nlink == 1,
      reopenedInfo.st_uid == layout.expectedOwnerUID,
      reopenedInfo.st_gid == layout.expectedGroupGID,
      reopenedInfo.st_mode & 0o7777 == 0o400,
      reopenedInfo.st_size == copied
    else {
      close(stagedFD)
      throw DaemonManagementError.unsafePath("staged daemon executable verification failed")
    }
    guard unlinkat(directory, temporaryName, 0) == 0 else {
      let message = String(cString: strerror(errno))
      close(stagedFD)
      throw DaemonManagementError.commandFailed(
        "unlink staged daemon executable: \(message)")
    }
    stagedLinked = false
    guard fsync(directory) == 0 else {
      let message = String(cString: strerror(errno))
      close(stagedFD)
      throw DaemonManagementError.commandFailed(
        "flush staged daemon executable cleanup: \(message)")
    }
    return stagedFD
  }

  private func writeManagedFiles(sourceFD: Int32, configuration: DaemonConfiguration) throws {
    try ensureDirectory(layout.statePath, mode: 0o700)
    try ensureDirectory(
      URL(fileURLWithPath: layout.socketPath).deletingLastPathComponent().path, mode: 0o755)
    try ensureParent(of: layout.executablePath, mode: 0o755)
    try ensureParent(of: layout.plistPath, mode: 0o755)
    try ensureParent(of: layout.configPath, mode: 0o700)
    try writeAtomically(from: sourceFD, to: layout.executablePath, mode: 0o755)
    try writeAtomically(plistData(), to: layout.plistPath, mode: 0o644)
    try writeAtomically(try configuration.data(), to: layout.configPath, mode: 0o600)
    try verifyManagedFile(layout.executablePath, mode: 0o755)
    try verifyManagedFile(layout.plistPath, mode: 0o644)
    try verifyManagedFile(layout.configPath, mode: 0o600)
  }

  private func writeAtomically(_ data: Data, to path: String, mode: mode_t) throws {
    try writeAtomically(to: path, mode: mode) { fd in
      var written = 0
      // Write straight from the Data storage; materializing a [UInt8] copy
      // would duplicate the whole payload before the write loop even starts.
      try data.withUnsafeBytes { buffer in
        while written < buffer.count {
          let amount = Darwin.write(
            fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
          if amount < 0 {
            if errno == EINTR { continue }
            throw DaemonManagementError.commandFailed(
              "write managed file: \(String(cString: strerror(errno)))")
          }
          guard amount > 0 else {
            throw DaemonManagementError.commandFailed("zero-length managed file write")
          }
          written += amount
        }
      }
    }
  }

  private func writeAtomically(from sourceFD: Int32, to path: String, mode: mode_t) throws {
    guard lseek(sourceFD, 0, SEEK_SET) >= 0 else {
      throw DaemonManagementError.commandFailed(
        "rewind daemon executable: \(String(cString: strerror(errno)))")
    }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    try writeAtomically(to: path, mode: mode) { destinationFD in
      var copied = false
      while true {
        let count = Darwin.read(sourceFD, &buffer, buffer.count)
        if count < 0 {
          if errno == EINTR { continue }
          throw DaemonManagementError.commandFailed(
            "read daemon executable: \(String(cString: strerror(errno)))")
        }
        if count == 0 { break }
        copied = true

        var written = 0
        while written < count {
          let amount = buffer.withUnsafeBytes { rawBuffer in
            Darwin.write(
              destinationFD,
              rawBuffer.baseAddress!.advanced(by: written),
              count - written)
          }
          if amount < 0 {
            if errno == EINTR { continue }
            throw DaemonManagementError.commandFailed(
              "write managed file: \(String(cString: strerror(errno)))")
          }
          guard amount > 0 else {
            throw DaemonManagementError.commandFailed("zero-length managed file write")
          }
          written += amount
        }
      }
      guard copied else {
        throw DaemonManagementError.unsafePath("daemon executable became empty")
      }
    }
  }

  private func writeAtomically(
    to path: String, mode: mode_t, body: (Int32) throws -> Void
  ) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let parentFD = try openDirectory(parent)
    defer { close(parentFD) }
    let basename = URL(fileURLWithPath: path).lastPathComponent
    let temporaryName = ".\(basename).tmp-\(UUID().uuidString)"
    let fd = openat(
      parentFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw DaemonManagementError.commandFailed(
        "create temporary managed file: \(String(cString: strerror(errno)))")
    }
    defer {
      close(fd)
      _ = unlinkat(parentFD, temporaryName, 0)
    }
    try body(fd)
    guard fchmod(fd, mode) == 0 else {
      throw DaemonManagementError.commandFailed(
        "set managed file mode: \(String(cString: strerror(errno)))")
    }
    guard fchown(fd, layout.expectedOwnerUID, layout.expectedGroupGID) == 0 else {
      throw DaemonManagementError.commandFailed(
        "set managed file ownership: \(String(cString: strerror(errno)))")
    }
    guard fsync(fd) == 0 else {
      throw DaemonManagementError.commandFailed(
        "flush managed file: \(String(cString: strerror(errno)))")
    }
    guard renameat(parentFD, temporaryName, parentFD, basename) == 0 else {
      throw DaemonManagementError.commandFailed(
        "publish managed file: \(String(cString: strerror(errno)))")
    }
    guard fsync(parentFD) == 0 else {
      throw DaemonManagementError.commandFailed(
        "flush managed file publication: \(String(cString: strerror(errno)))")
    }
  }

  private func verifyManagedFile(_ path: String, mode: mode_t) throws {
    var info = stat()
    guard lstat(path, &info) == 0,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1,
      info.st_uid == layout.expectedOwnerUID,
      info.st_gid == layout.expectedGroupGID,
      info.st_mode & 0o7777 == mode
    else {
      throw DaemonManagementError.unsafePath("managed file verification failed: \(path)")
    }
  }

  private func ensureParent(of path: String, mode: mode_t) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try ensureDirectory(parent, mode: mode)
  }

  func ensureDirectory(_ path: String, mode: mode_t) throws {
    let path = normalizeKnownSystemAlias(path)
    guard path.hasPrefix("/"), path != "/" else {
      if path == "/" { return }
      throw DaemonManagementError.unsafePath("managed directory must be absolute: \(path)")
    }
    var current = ""
    let components = path.split(separator: "/").map(String.init)
    for (index, component) in components.enumerated() {
      current += "/" + component
      var info = stat()
      if lstat(current, &info) != 0 {
        guard errno == ENOENT else {
          throw DaemonManagementError.unsafePath(
            "cannot inspect managed directory \(current): \(String(cString: strerror(errno)))")
        }
        guard mkdir(current, mode) == 0 else {
          throw DaemonManagementError.unsafePath(
            "cannot create managed directory \(current): \(String(cString: strerror(errno)))")
        }
        guard chown(current, layout.expectedOwnerUID, layout.expectedGroupGID) == 0,
          chmod(current, mode) == 0
        else {
          throw DaemonManagementError.unsafePath(
            "cannot secure managed directory \(current): \(String(cString: strerror(errno)))")
        }
        continue
      }
      guard info.st_mode & S_IFMT == S_IFDIR else {
        throw DaemonManagementError.unsafePath("managed path is not a directory: \(current)")
      }
      // Existing system ancestors (/var, /Library, /tmp) may be root-owned;
      // newly created and final managed directories must belong to the target
      // owner. All existing ancestors must still be non-writable by others,
      // except conventional sticky directories and macOS's root:daemon
      // runtime ancestor. Neither exception applies to our own directory.
      let isFinal = index == components.count - 1
      if isFinal {
        guard info.st_uid == layout.expectedOwnerUID else {
          throw DaemonManagementError.unsafePath("managed parent owner is unsafe: \(current)")
        }
        guard info.st_mode & 0o022 == 0 else {
          throw DaemonManagementError.unsafePath("managed directory is writable by others: \(current)")
        }
        let sharedSystemDirectory = current == "/Library/LaunchDaemons"
          || current == "/Library/PrivilegedHelperTools"
        if !sharedSystemDirectory && info.st_mode & 0o7777 != mode {
          guard chmod(current, mode) == 0 else {
            throw DaemonManagementError.unsafePath("cannot set managed directory mode: \(current)")
          }
        }
      } else {
        guard info.st_uid == 0 || info.st_uid == layout.expectedOwnerUID else {
          throw DaemonManagementError.unsafePath("managed parent owner is unsafe: \(current)")
        }
      }
      let writableByOthers = info.st_mode & 0o022 != 0
      let sticky = info.st_mode & S_ISVTX != 0
      let systemRuntimeAncestor = Self.isSystemRuntimeAncestor(current, info: info, isFinal: isFinal)
      guard !writableByOthers || sticky || systemRuntimeAncestor else {
        throw DaemonManagementError.unsafePath("managed directory is writable by others: \(current)")
      }
    }
  }

  // /private/var/run is shipped root:daemon 0775 on macOS. Trust only
  // that exact system ancestor, never arbitrary group-writable directories
  // or the dopa directory itself. The daemon system group has GID 1.
  static func isSystemRuntimeAncestor(_ path: String, info: stat, isFinal: Bool) -> Bool {
    !isFinal && path == "/private/var/run"
      && info.st_mode & S_IFMT == S_IFDIR
      && info.st_uid == 0 && info.st_gid == 1
      && info.st_mode & 0o7777 == 0o775
  }

  private func normalizeKnownSystemAlias(_ path: String) -> String {
    for alias in ["/var", "/tmp"] {
      guard path == alias || path.hasPrefix(alias + "/") else { continue }
      var info = stat()
      guard lstat(alias, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { continue }
      guard let target = readlinkTarget(alias) else { continue }
      if target == "/private\(alias)" || target == "private\(alias)" {
        return "/private" + path
      }
    }
    return path
  }

  private func readlinkTarget(_ path: String) -> String? {
    var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
    let count = readlink(path, &bytes, bytes.count - 1)
    guard count > 0 else { return nil }
    return String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
  }

  private func openDirectory(_ path: String) throws -> Int32 {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      throw DaemonManagementError.unsafePath("managed parent does not exist: \(path)")
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == layout.expectedOwnerUID,
      info.st_mode & 0o022 == 0
    else {
      throw DaemonManagementError.unsafePath("managed parent is unsafe: \(path)")
    }
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DaemonManagementError.unsafePath("cannot open managed parent: \(path)") }
    return fd
  }

  private func removeManagedFile(_ path: String) throws {
    let snapshot = try snapshot(path)
    guard snapshot.exists else { return }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let parentFD = try openDirectory(parent)
    defer { close(parentFD) }
    let basename = URL(fileURLWithPath: path).lastPathComponent
    guard unlinkat(parentFD, basename, 0) == 0 else {
      throw DaemonManagementError.commandFailed("remove managed file \(path): \(String(cString: strerror(errno)))")
    }
    guard fsync(parentFD) == 0 else {
      throw DaemonManagementError.commandFailed("flush managed file removal: \(String(cString: strerror(errno)))")
    }
  }

  private func restore(snapshots: [FileSnapshot]) throws {
    for snapshot in snapshots {
      if snapshot.exists {
        guard let data = snapshot.data else { continue }
        try writeAtomically(data, to: snapshot.path, mode: snapshot.mode)
      } else {
        try removeManagedFile(snapshot.path)
      }
    }
  }

  private func rollback(
    to snapshots: [FileSnapshot], serviceWasInstalled: Bool, bootstrapAttempted: Bool
  ) throws {
    // A bootstrap attempt may have registered a service even when launchctl
    // returned an error. Never replace or remove the executable until bootout
    // has positively completed; leaving the files in place preserves a live
    // daemon's recovery journal for a later retry.
    if bootstrapAttempted {
      // Stop accepting clients and verify both assertion and SleepDisabled
      // cleanup through the daemon before asking launchd to remove it. If the
      // daemon cannot confirm recovery, this throws and leaves every new file
      // and its journal untouched for an operator to inspect.
      try requestShutdown()
      try bootout()
    }
    try restore(snapshots: snapshots)
    if serviceWasInstalled {
      try bootstrap()
      try waitUntilReady()
    }
  }

  private func prepareAndBootoutExistingService() throws {
    do {
      try requestShutdown()
    } catch let error as DaemonManagementError {
      // A previous installation may have a valid plist but no live daemon
      // (for example after a crash). Start that exact installation first so
      // its journal can perform the required orderly shutdown.
      guard case .serviceUnavailable = error else { throw error }
      try startExistingService()
      try requestShutdown()
    } catch {
      // A response from the daemon (including recovery_failed) must be
      // propagated without starting or force-kicking it again.
      throw error
    }
    try bootout()
  }

  private func startExistingService() throws {
    let bootstrap = try commandRunner.run(
      executable: "/bin/launchctl", arguments: ["bootstrap", "system", layout.plistPath])
    if !bootstrap.succeeded {
      let kickstart = try commandRunner.run(
        executable: "/bin/launchctl", arguments: ["kickstart", layout.serviceTarget])
      guard kickstart.succeeded else {
        throw DaemonManagementError.serviceUnavailable(
          "cannot start existing daemon: \(kickstart.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
    }
  }

  private func requestShutdown() throws {
    if let shutdownRequester {
      try shutdownRequester(layout.socketPath)
      return
    }

    var lastError: Error?
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      let connection: DopaConnection
      do {
        connection = try DopaConnection(
          path: layout.socketPath, requireRoot: true, clientName: "dopa-daemon")
      } catch let error as DopaClientError {
        lastError = error
        switch error {
        case .socketPathMissing, .socketFailure, .timedOut:
          usleep(50_000)
          continue
        default:
          throw error
        }
      } catch {
        throw error
      }
      do {
        _ = try connection.request(method: "admin.prepareShutdown", params: .object([:]))
        connection.close()
        return
      } catch {
        // A declared daemon-side recovery or power error, and any timeout
        // after connecting, are authoritative. Do not replay them.
        connection.close()
        throw error
      }
    }
    throw DaemonManagementError.serviceUnavailable(
      "cannot prepare the existing daemon for shutdown: \(lastError.map(String.init(describing:)) ?? "unknown error")")
  }

  private func waitUntilReady() throws {
    if let readinessChecker {
      guard readinessChecker(layout.socketPath) else {
        throw DaemonManagementError.serviceUnavailable("new daemon did not become ready")
      }
      return
    }
    var lastError: Error?
    let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      let connection: DopaConnection
      do {
        connection = try DopaConnection(
          path: layout.socketPath, requireRoot: true, clientName: "dopa-daemon")
      } catch let error as DopaClientError {
        lastError = error
        switch error {
        case .socketPathMissing, .socketFailure, .timedOut:
          usleep(50_000)
          continue
        default:
          throw error
        }
      } catch {
        throw error
      }
      do {
        let snapshot = try connection.request(method: "status.get", params: .object([:]))
        connection.close()
        let phase = snapshot["phase"]?.stringValue
        guard phase == "idle" || phase == "active",
          phase == "active" || snapshot["recoveryPending"]?.boolValue != true
        else {
          throw DaemonManagementError.serviceUnavailable(
            "new daemon is not healthy (phase: \(phase ?? "unknown"))")
        }
        return
      } catch {
        connection.close()
        throw error
      }
    }
    throw DaemonManagementError.serviceUnavailable(
      "new daemon did not become ready: \(lastError.map(String.init(describing:)) ?? "unknown error")")
  }

  private func bootstrap() throws {
    let result = try commandRunner.run(
      executable: "/bin/launchctl", arguments: ["bootstrap", "system", layout.plistPath])
    guard result.succeeded else {
      throw DaemonManagementError.commandFailed(
        "launchctl bootstrap failed (\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }

  private func bootout() throws {
    let result = try commandRunner.run(
      executable: "/bin/launchctl", arguments: ["bootout", layout.serviceTarget])
    guard result.succeeded || isMissingService(result) else {
      throw DaemonManagementError.commandFailed(
        "launchctl bootout failed (\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }

  private func isMissingService(_ result: CommandResult) -> Bool {
    guard result.status != 0 else { return false }
    let text = (result.stdout + "\n" + result.stderr).lowercased()
    return text.contains("no such process") || text.contains("service not found")
      || text.contains("could not find service") || text.contains("not found")
  }

  private func plistData() throws -> Data {
    let executable = xmlEscape(layout.executablePath)
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>\(xmlEscape(layout.serviceLabel))</string>
        <key>ProgramArguments</key>
        <array>
          <string>\(executable)</string>
          <string>run</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>ProcessType</key>
        <string>Background</string>
      </dict>
      </plist>
      """
    guard let data = plist.data(using: .utf8) else {
      throw DaemonManagementError.invalidConfiguration("cannot encode launchd plist")
    }
    return data
  }

  private func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

public enum DaemonStatusFormatter {
  public static func json(_ snapshot: JSONValue) throws -> String {
    let data = try JSONWire.encode(snapshot)
    guard let text = String(data: data, encoding: .utf8) else {
      throw DaemonManagementError.invalidConfiguration("status is not valid UTF-8")
    }
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
  }

  public static func human(_ snapshot: JSONValue) -> String {
    let phase = snapshot["phase"]?.stringValue ?? "unknown"
    let desired = snapshot["desired"]
    let confirmed = snapshot["confirmed"]
    let sessions = snapshot["sessions"]?.arrayValue?.count ?? 0
    let sleep = powerState(desired: desired, confirmed: confirmed, key: "systemSleepDisabled")
    let display = powerState(desired: desired, confirmed: confirmed, key: "keepDisplayOn")
    let recovery = snapshot["recoveryPending"]?.boolValue == true ? "pending" : "clear"
    var lines = [
      "phase: \(phase)",
      "sleep inhibition: \(sleep)",
      "display assertion: \(display)",
      "sessions: \(sessions)",
      "recovery: \(recovery)",
    ]
    if let sessionValues = snapshot["sessions"]?.arrayValue {
      for session in sessionValues {
        let id = session["id"]?.stringValue ?? "?"
        let name = session["clientName"]?.stringValue ?? "?"
        let uid = numberText(session["peerUID"]) ?? "?"
        let pid = numberText(session["peerPID"]) ?? "?"
        let options = session["options"]
        let displayOption = options?["keepDisplayOn"]?.boolValue == true ? "on" : "off"
        lines.append(
          "session \(id): client=\(name) uid=\(uid) pid=\(pid) display=\(displayOption)")
      }
    }
    if let error = snapshot["lastError"], case .object = error {
      let code = error["code"]?.stringValue ?? "unknown"
      let message = error["message"]?.stringValue ?? ""
      lines.append("error: \(code)\(message.isEmpty ? "" : " — \(message)")")
    }
    return lines.joined(separator: "\n")
  }

  private static func powerState(
    desired: JSONValue?, confirmed: JSONValue?, key: String
  ) -> String {
    if confirmed?[key]?.boolValue == true { return "on (confirmed)" }
    if confirmed?[key]?.boolValue == false { return "off (confirmed)" }
    if desired?[key]?.boolValue == true { return "on (unconfirmed)" }
    if desired?[key]?.boolValue == false { return "off (unconfirmed)" }
    return "unknown"
  }

  private static func numberText(_ value: JSONValue?) -> String? {
    guard case .number(let number) = value else { return nil }
    guard number.isFinite else { return nil }
    if number.rounded() == number,
      number >= Double(Int64.min), number <= Double(Int64.max)
    {
      return String(Int64(number))
    }
    return String(number)
  }
}
