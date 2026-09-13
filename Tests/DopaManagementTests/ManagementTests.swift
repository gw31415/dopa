import Darwin
@testable import DopaManagement
import DopaProtocol
import Foundation
import XCTest

final class ManagementTests: XCTestCase {
  private final class Counter: @unchecked Sendable {
    var value = 0
  }

  private final class FakeRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable {
      let executable: String
      let arguments: [String]
    }

    var calls: [Call] = []
    var results: [CommandResult] = []

    func run(executable: String, arguments: [String]) throws -> CommandResult {
      calls.append(Call(executable: executable, arguments: arguments))
      if !results.isEmpty { return results.removeFirst() }
      return CommandResult(status: 0)
    }
  }

  private struct Fixture {
    let root: URL
    let layout: DaemonLayout
    let source: URL

    init() throws {
      root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
        "dopa-management-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o755)])
      layout = DaemonLayout.temporary(rootDirectory: root)
      source = root.appendingPathComponent("dopa-daemon-source")
      try Data("daemon-binary-v1".utf8).write(to: source)
      XCTAssertEqual(chmod(source.path, 0o755), 0)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  private func manager(
    _ fixture: Fixture,
    runner: FakeRunner,
    shutdownCount: Counter? = nil,
    readiness: @escaping ReadinessChecker = { _ in true }
  ) -> DaemonManager {
    DaemonManager(
      layout: fixture.layout,
      commandRunner: runner,
      shutdownRequester: { _ in shutdownCount?.value += 1 },
      readinessChecker: readiness,
      requireRoot: false)
  }

  func testSystemRuntimeAncestorAcceptsOnlyStandardMacOSMetadata() throws {
    var info = stat()
    XCTAssertEqual(lstat("/private/var/run", &info), 0)
    // Exercise real host metadata: temporary fixtures normally have 0755
    // parents and did not reveal the standard root:daemon 0775 ancestor.
    if info.st_uid == 0 && info.st_gid == 1 && info.st_mode & 0o7777 == 0o775 {
      XCTAssertTrue(DaemonManager.isSystemRuntimeAncestor("/private/var/run", info: info, isFinal: false))
    }
    info.st_mode = mode_t(S_IFDIR) | 0o775
    info.st_uid = 0
    info.st_gid = 1
    XCTAssertTrue(DaemonManager.isSystemRuntimeAncestor("/private/var/run", info: info, isFinal: false))
    XCTAssertFalse(DaemonManager.isSystemRuntimeAncestor("/private/var/run", info: info, isFinal: true))
    XCTAssertFalse(DaemonManager.isSystemRuntimeAncestor("/private/var/run/dopa", info: info, isFinal: false))
    XCTAssertFalse(DaemonManager.isSystemRuntimeAncestor("/tmp/run", info: info, isFinal: false))
    info.st_gid = 20
    XCTAssertFalse(DaemonManager.isSystemRuntimeAncestor("/private/var/run", info: info, isFinal: false))
    info.st_gid = 1
    info.st_uid = 501
    XCTAssertFalse(DaemonManager.isSystemRuntimeAncestor("/private/var/run", info: info, isFinal: false))
    info.st_uid = 0
    info.st_mode = mode_t(S_IFDIR) | 0o777
    XCTAssertFalse(DaemonManager.isSystemRuntimeAncestor("/private/var/run", info: info, isFinal: false))
  }

  func testWritableManagedDirectoryIsStillRejected() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    XCTAssertEqual(chmod(directory.path, 0o775), 0)
    let installer = manager(fixture, runner: FakeRunner())
    XCTAssertThrowsError(try installer.ensureDirectory(directory.path, mode: 0o755))
    var info = stat()
    XCTAssertEqual(lstat(directory.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o775)
  }

  func testSharedSystemHelperDirectoryIsNotChmodded() throws {
    guard geteuid() != 0 else { throw XCTSkip("host directory check is read-only as non-root") }
    let path = "/Library/PrivilegedHelperTools"
    var before = stat()
    guard lstat(path, &before) == 0 else { throw XCTSkip("shared helper directory absent") }
    try DaemonManager().ensureDirectory(path, mode: 0o755)
    var after = stat()
    XCTAssertEqual(lstat(path, &after), 0)
    XCTAssertEqual(before.st_mode, after.st_mode)
    XCTAssertEqual(before.st_uid, after.st_uid)
    XCTAssertEqual(before.st_gid, after.st_gid)
  }

  func testInstallUpdatesAndUninstallPreserveUserAndSecureFiles() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    let installer = manager(fixture, runner: runner, shutdownCount: shutdowns)
    let user = String(geteuid())

    try installer.install(executableURL: fixture.source, user: user)
    XCTAssertEqual(shutdowns.value, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.executablePath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.plistPath))
    let configuration = try DaemonConfiguration.loadSecure(
      from: fixture.layout.configPath,
      ownerUID: geteuid(), groupGID: getegid(), mode: 0o600)
    XCTAssertEqual(configuration.allowedUID, geteuid())
    XCTAssertEqual(
      try String(contentsOfFile: fixture.layout.plistPath),
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>dev.amas.dopa.daemon.test</string>
        <key>ProgramArguments</key>
        <array>
          <string>\(fixture.layout.executablePath)</string>
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
    )
    XCTAssertTrue(
      runner.calls.contains { $0.arguments == ["bootstrap", "system", fixture.layout.plistPath] })

    let updateSource = fixture.root.appendingPathComponent("dopa-daemon-source-v2")
    try Data("daemon-binary-v2".utf8).write(to: updateSource)
    XCTAssertEqual(chmod(updateSource.path, 0o755), 0)
    try installer.install(executableURL: updateSource)
    XCTAssertEqual(shutdowns.value, 1)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.layout.executablePath)),
                   Data("daemon-binary-v2".utf8))
    XCTAssertEqual(try DaemonConfiguration.load(from: fixture.layout.configPath).allowedUID, geteuid())

    try installer.uninstall()
    XCTAssertEqual(shutdowns.value, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.executablePath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.plistPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.configPath))
    XCTAssertTrue(
      runner.calls.filter { $0.arguments.first == "bootout" }.count >= 2)
  }

  func testUpdateBootstrapFailureRestoresPreviousInstallation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    let installer = manager(fixture, runner: runner, shutdownCount: shutdowns)
    try installer.install(executableURL: fixture.source, user: String(geteuid()))
    let oldBinary = try Data(contentsOf: URL(fileURLWithPath: fixture.layout.executablePath))
    let oldPlist = try Data(contentsOf: URL(fileURLWithPath: fixture.layout.plistPath))
    let oldConfig = try Data(contentsOf: URL(fileURLWithPath: fixture.layout.configPath))

    let updateSource = fixture.root.appendingPathComponent("dopa-daemon-source-v2")
    try Data("daemon-binary-v2".utf8).write(to: updateSource)
    XCTAssertEqual(chmod(updateSource.path, 0o755), 0)
    // Existing bootout, failed new bootstrap, rollback bootout, old bootstrap.
    runner.results = [
      CommandResult(status: 0), CommandResult(status: 17, stderr: "bootstrap failed"),
      CommandResult(status: 0), CommandResult(status: 0),
    ]

    XCTAssertThrowsError(try installer.install(executableURL: updateSource))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: fixture.layout.executablePath)), oldBinary)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.layout.plistPath)), oldPlist)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.layout.configPath)), oldConfig)
    XCTAssertEqual(shutdowns.value, 2, "new service cleanup must be confirmed before rollback")
  }

  func testLegacyServiceIdentityIsReplacedAndConfiguredUserIsPreserved() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let legacyLayout = DaemonLayout(
      serviceLabel: "dev.dopa.daemon.test",
      plistPath: fixture.root.appendingPathComponent(
        "LaunchDaemons/dev.dopa.daemon.plist").path,
      executablePath: fixture.root.appendingPathComponent(
        "PrivilegedHelperTools/dev.dopa.daemon").path,
      configPath: fixture.layout.configPath,
      statePath: fixture.layout.statePath,
      socketPath: fixture.layout.socketPath,
      expectedOwnerUID: geteuid(),
      expectedGroupGID: getegid())
    let runner = FakeRunner()
    let shutdowns = Counter()
    let legacyManager = DaemonManager(
      layout: legacyLayout,
      commandRunner: runner,
      shutdownRequester: { _ in shutdowns.value += 1 },
      readinessChecker: { _ in true },
      requireRoot: false)
    try legacyManager.install(
      executableURL: fixture.source, user: String(geteuid()))
    runner.calls.removeAll()

    let currentManager = manager(
      fixture, runner: runner, shutdownCount: shutdowns)
    try currentManager.installReplacingLegacy(
      executableURL: fixture.source,
      legacyLayout: legacyLayout,
      environment: [:])

    XCTAssertEqual(shutdowns.value, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLayout.plistPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLayout.executablePath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.plistPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.executablePath))
    XCTAssertEqual(
      try DaemonConfiguration.load(from: fixture.layout.configPath).allowedUID,
      geteuid())
    XCTAssertEqual(
      runner.calls.map(\.arguments),
      [
        ["bootout", legacyLayout.serviceTarget],
        ["bootstrap", "system", fixture.layout.plistPath],
      ])
  }

  func testFreshBootstrapFailureKeepsFilesWhenServiceCannotBeStopped() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    let installer = manager(fixture, runner: runner, shutdownCount: shutdowns)
    // Failed bootstrap followed by a failed rollback bootout. The new files
    // remain available for recovery instead of being removed blindly.
    runner.results = [
      CommandResult(status: 17, stderr: "bootstrap failed"),
      CommandResult(status: 18, stderr: "cannot bootout"),
    ]
    XCTAssertThrowsError(try installer.install(executableURL: fixture.source, user: String(geteuid()))) {
      XCTAssertTrue($0 is DaemonManagementError)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.executablePath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.plistPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.configPath))
    XCTAssertEqual(shutdowns.value, 1)
  }

  func testFreshInstallRefusesALegacyGuardianStateLock() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      atPath: fixture.layout.statePath, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let lockPath = fixture.layout.statePath + "/lock"
    FileManager.default.createFile(atPath: lockPath, contents: nil)
    XCTAssertEqual(chmod(lockPath, 0o600), 0)
    XCTAssertEqual(chown(lockPath, geteuid(), getegid()), 0)
    let lock = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(lock, 0)
    guard lock >= 0 else { return }
    defer { close(lock) }
    XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)

    let runner = FakeRunner()
    let installer = manager(fixture, runner: runner)
    XCTAssertThrowsError(
      try installer.install(executableURL: fixture.source, user: String(geteuid()))) {
        guard case .serviceUnavailable = ($0 as? DaemonManagementError) else {
          return XCTFail("expected state-lock refusal, got \($0)")
        }
      }
    XCTAssertTrue(runner.calls.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.executablePath))
  }

  func testUnsafeSymlinkAndUnsafeConfigurationAreRejected() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let victim = fixture.root.appendingPathComponent("victim")
    try Data("do not replace".utf8).write(to: victim)
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("state"), withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("LaunchDaemons"), withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o755)])
    try FileManager.default.createSymbolicLink(
      atPath: fixture.layout.plistPath,
      withDestinationPath: victim.path)

    let runner = FakeRunner()
    let installer = manager(fixture, runner: runner)
    XCTAssertThrowsError(try installer.install(executableURL: fixture.source, user: String(geteuid())))
    XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "do not replace")
    XCTAssertTrue(runner.calls.isEmpty)

    for data in [
      Data(#"{"version":true,"allowedUID":501}"#.utf8),
      Data(#"{"version":1.5,"allowedUID":501}"#.utf8),
      Data(#"{"version":1,"allowedUID":501,"extra":0}"#.utf8),
    ] {
      XCTAssertThrowsError(try DaemonConfiguration(data: data))
    }
  }

  func testInstallCannotChangeConfiguredUserImplicitlyOrExplicitly() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    let installer = manager(fixture, runner: runner, shutdownCount: shutdowns)
    try installer.install(executableURL: fixture.source, user: String(geteuid()))
    let callsBefore = runner.calls.count
    let differentUID: uid_t = geteuid() == 0 ? 501 : 0
    guard getpwuid(differentUID) != nil else { throw XCTSkip("test account unavailable") }
    XCTAssertThrowsError(
      try installer.install(executableURL: fixture.source, user: String(differentUID)))
    XCTAssertEqual(runner.calls.count, callsBefore)
    XCTAssertEqual(shutdowns.value, 0)
  }

  func testStartBootstrapsInstalledServiceAndWaitsUntilReady() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    var readinessChecks = 0
    let installer = manager(
      fixture,
      runner: runner,
      readiness: { _ in
        readinessChecks += 1
        return true
      })
    try installer.install(executableURL: fixture.source, user: String(geteuid()))
    runner.calls.removeAll()
    readinessChecks = 0

    try installer.start()

    XCTAssertEqual(
      runner.calls.map(\.arguments),
      [["bootstrap", "system", fixture.layout.plistPath]])
    XCTAssertEqual(readinessChecks, 1)
  }

  func testStopConfirmsShutdownBeforeBootout() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    let installer = manager(fixture, runner: runner, shutdownCount: shutdowns)
    try installer.install(executableURL: fixture.source, user: String(geteuid()))
    runner.calls.removeAll()

    try installer.stop()

    XCTAssertEqual(shutdowns.value, 1)
    XCTAssertEqual(
      runner.calls.map(\.arguments),
      [["bootout", fixture.layout.serviceTarget]])
  }

  func testStopStartsDisconnectedInstalledServiceForJournalRecovery() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    var firstShutdown = true
    let installer = DaemonManager(
      layout: fixture.layout,
      commandRunner: runner,
      shutdownRequester: { _ in
        shutdowns.value += 1
        if firstShutdown {
          firstShutdown = false
          throw DaemonManagementError.serviceUnavailable("daemon is not connected")
        }
      },
      readinessChecker: { _ in true },
      requireRoot: false)
    try installer.install(executableURL: fixture.source, user: String(geteuid()))
    runner.calls.removeAll()
    runner.results = [
      CommandResult(status: 17, stderr: "service already bootstrapped"),
      CommandResult(status: 0),
      CommandResult(status: 0),
    ]

    try installer.stop()

    XCTAssertEqual(shutdowns.value, 2)
    XCTAssertEqual(
      runner.calls.map(\.arguments),
      [
        ["bootstrap", "system", fixture.layout.plistPath],
        ["kickstart", fixture.layout.serviceTarget],
        ["bootout", fixture.layout.serviceTarget],
      ])
  }

  func testRestartSafelyStopsThenBootstrapsAndWaitsUntilReady() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    var readinessChecks = 0
    let installer = DaemonManager(
      layout: fixture.layout,
      commandRunner: runner,
      shutdownRequester: { _ in shutdowns.value += 1 },
      readinessChecker: { _ in
        readinessChecks += 1
        return true
      },
      requireRoot: false)
    try installer.install(executableURL: fixture.source, user: String(geteuid()))
    runner.calls.removeAll()
    readinessChecks = 0

    try installer.restart()

    XCTAssertEqual(shutdowns.value, 1)
    XCTAssertEqual(
      runner.calls.map(\.arguments),
      [
        ["bootout", fixture.layout.serviceTarget],
        ["bootstrap", "system", fixture.layout.plistPath],
      ])
    XCTAssertEqual(readinessChecks, 1)
  }

  func testLifecycleCommandsRejectMissingOrUnsafeInstallations() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let manager = manager(fixture, runner: runner)

    for operation in [
      { try manager.start() },
      { try manager.stop() },
      { try manager.restart() },
    ] {
      XCTAssertThrowsError(try operation()) { error in
        guard case .invalidConfiguration(let message) = (error as? DaemonManagementError) else {
          return XCTFail("expected missing-installation error, got \(error)")
        }
        XCTAssertTrue(message.contains("not installed"))
      }
    }
    XCTAssertTrue(runner.calls.isEmpty)

    try manager.install(executableURL: fixture.source, user: String(geteuid()))
    XCTAssertEqual(chmod(fixture.layout.executablePath, 0o744), 0)
    runner.calls.removeAll()
    XCTAssertThrowsError(try manager.start()) { error in
      guard case .unsafePath = (error as? DaemonManagementError) else {
        return XCTFail("expected unsafe-installation error, got \(error)")
      }
    }
    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testStatusFormatterIncludesSessionIdentityAndOptions() throws {
    let snapshot: JSONValue = .object([
      "phase": .string("active"),
      "desired": .object(["systemSleepDisabled": .bool(true), "keepDisplayOn": .bool(false)]),
      "confirmed": .object([
        "systemSleepDisabled": .bool(true), "keepDisplayOn": .bool(false),
      ]),
      "sessions": .array([
        .object([
          "id": .string("session-1"), "clientName": .string("editor"),
          "peerUID": .number(501), "peerPID": .number(42),
          "options": .object(["keepDisplayOn": .bool(false), "stopOnLidClose": .bool(true)]),
        ])
      ]),
      "recoveryPending": .bool(false), "lastError": .null,
    ])
    let output = DaemonStatusFormatter.human(snapshot)
    XCTAssertTrue(output.contains("session-1"))
    XCTAssertTrue(output.contains("client=editor"))
    XCTAssertTrue(output.contains("uid=501"))
    XCTAssertTrue(output.contains("pid=42"))
    XCTAssertTrue(output.contains("lid-close=on"))
    XCTAssertEqual(try JSONWire.decode(Data((try DaemonStatusFormatter.json(snapshot)).utf8)), snapshot)
  }
}
