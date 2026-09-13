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

  private final class BlockingRunner: CommandRunner, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls: [FakeRunner.Call] = []
    private var blockNextBootout = false
    private var bootoutIsBlocked = false
    private var releaseBootout = false

    func run(executable: String, arguments: [String]) throws -> CommandResult {
      condition.lock()
      calls.append(FakeRunner.Call(executable: executable, arguments: arguments))
      if blockNextBootout && arguments.first == "bootout" {
        blockNextBootout = false
        bootoutIsBlocked = true
        condition.broadcast()
        while !releaseBootout { condition.wait() }
      }
      condition.unlock()
      return CommandResult(status: 0)
    }

    func resetAndBlockNextBootout() {
      condition.lock()
      calls.removeAll()
      blockNextBootout = true
      bootoutIsBlocked = false
      releaseBootout = false
      condition.unlock()
    }

    func waitUntilBootoutIsBlocked(timeout: TimeInterval) -> Bool {
      condition.lock()
      defer { condition.unlock() }
      let deadline = Date().addingTimeInterval(timeout)
      while !bootoutIsBlocked {
        if !condition.wait(until: deadline) { return false }
      }
      return true
    }

    func releaseBlockedBootout() {
      condition.lock()
      releaseBootout = true
      condition.broadcast()
      condition.unlock()
    }

    var callCount: Int {
      condition.lock()
      defer { condition.unlock() }
      return calls.count
    }
  }

  private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func capture(_ body: () throws -> Void) {
      do {
        try body()
      } catch {
        lock.lock()
        stored = error
        lock.unlock()
      }
    }

    var error: Error? {
      lock.lock()
      defer { lock.unlock() }
      return stored
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

  private func executableBytes(size: Int, seed: UInt64) -> Data {
    var bytes = Data(count: size)
    bytes.withUnsafeMutableBytes { raw in
      var state = seed
      for index in 0..<raw.count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        raw[index] = UInt8(truncatingIfNeeded: (state >> 33) ^ UInt64(index))
      }
    }
    return bytes
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

  private func legacyLayout(for fixture: Fixture) -> DaemonLayout {
    DaemonLayout(
      serviceLabel: "dev.dopa.daemon.test",
      plistPath: fixture.root.appendingPathComponent(
        "LaunchDaemons/dev.dopa.daemon.plist"
      ).path,
      executablePath: fixture.root.appendingPathComponent(
        "PrivilegedHelperTools/dev.dopa.daemon"
      ).path,
      configPath: fixture.layout.configPath,
      statePath: fixture.layout.statePath,
      socketPath: fixture.layout.socketPath,
      expectedOwnerUID: geteuid(),
      expectedGroupGID: getegid())
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

  func testInstallPreservesLargeExecutableByteIdentical() throws {
    // A multi-megabyte executable exercises bounded-memory staging
    // and atomic destination writes. It must install byte-identical with no
    // new size limit, keeping executable permissions.
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let installer = manager(fixture, runner: runner)
    let bytes = executableBytes(size: 5 * 1024 * 1024, seed: 0x1234_5678_9ABC_DEF0)
    let largeSource = fixture.root.appendingPathComponent("dopa-daemon-large")
    try bytes.write(to: largeSource)
    XCTAssertEqual(chmod(largeSource.path, 0o755), 0)
    try installer.install(executableURL: largeSource, user: String(geteuid()))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: fixture.layout.executablePath)), bytes)
    XCTAssertEqual(access(fixture.layout.executablePath, X_OK), 0)
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

  func testLargeExistingUpdateRollbackPreservesBytesAndCleansTemporaryFiles() throws {
    // An update must retain a byte-identical rollback image even when the
    // replacement is large. The manager stages the replacement with a bounded
    // buffer, so this path does not need a second full Data allocation for the
    // new executable.
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    let shutdowns = Counter()
    let installer = manager(fixture, runner: runner, shutdownCount: shutdowns)
    let oldBytes = executableBytes(size: 5 * 1024 * 1024, seed: 0x11)
    let oldSource = fixture.root.appendingPathComponent("dopa-daemon-source-old")
    try oldBytes.write(to: oldSource)
    XCTAssertEqual(chmod(oldSource.path, 0o755), 0)
    try installer.install(executableURL: oldSource, user: String(geteuid()))

    let newBytes = executableBytes(size: 5 * 1024 * 1024, seed: 0x22)
    let newSource = fixture.root.appendingPathComponent("dopa-daemon-source-new")
    try newBytes.write(to: newSource)
    XCTAssertEqual(chmod(newSource.path, 0o755), 0)
    // Existing bootout, failed new bootstrap, rollback bootout, old bootstrap.
    runner.results = [
      CommandResult(status: 0), CommandResult(status: 17),
      CommandResult(status: 0), CommandResult(status: 0),
    ]

    XCTAssertThrowsError(try installer.install(executableURL: newSource))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: fixture.layout.executablePath)), oldBytes)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: fixture.layout.executablePath).deletingLastPathComponent(),
        includingPropertiesForKeys: nil
      ).contains { $0.lastPathComponent.contains(".tmp-") })
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: fixture.layout.plistPath).deletingLastPathComponent(),
        includingPropertiesForKeys: nil
      ).contains { $0.lastPathComponent.contains(".tmp-") })
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: fixture.layout.statePath)
        .contains { $0.hasPrefix(".candidate-") })
    XCTAssertEqual(shutdowns.value, 2)
  }

  func testUpdatePublishesFullyStagedCandidateWhenSourceChangesDuringShutdown() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = FakeRunner()
    try manager(fixture, runner: runner).install(
      executableURL: fixture.source, user: String(geteuid()))

    let candidate = Data("candidate-before-service-stop".utf8)
    let mutation = Data("source-mutated-during-stop".utf8)
    let updateSource = fixture.root.appendingPathComponent("dopa-daemon-update-source")
    try candidate.write(to: updateSource)
    XCTAssertEqual(chmod(updateSource.path, 0o755), 0)
    let updater = DaemonManager(
      layout: fixture.layout,
      commandRunner: runner,
      shutdownRequester: { _ in
        let fd = open(updateSource.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard fd >= 0 else {
          throw DaemonManagementError.commandFailed("cannot mutate source fixture")
        }
        defer { close(fd) }
        try mutation.withUnsafeBytes { bytes in
          var written = 0
          while written < bytes.count {
            let count = Darwin.write(
              fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
            guard count > 0 else {
              throw DaemonManagementError.commandFailed("cannot mutate source fixture")
            }
            written += count
          }
        }
      },
      readinessChecker: { _ in true },
      requireRoot: false)

    try updater.install(executableURL: updateSource)

    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: fixture.layout.executablePath)), candidate)
    XCTAssertEqual(try Data(contentsOf: updateSource), mutation)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: fixture.layout.statePath)
        .contains { $0.hasPrefix(".candidate-") })
  }

  func testLegacyServiceIdentityIsReplacedAndConfiguredUserIsPreserved() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let legacyLayout = legacyLayout(for: fixture)
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

  func testFailedLegacyMigrationRestoresExactIdentityAndWaitsUntilReady() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let legacyLayout = legacyLayout(for: fixture)
    let runner = FakeRunner()
    let shutdowns = Counter()
    var readinessChecks = 0
    let legacyManager = DaemonManager(
      layout: legacyLayout,
      commandRunner: runner,
      shutdownRequester: { _ in shutdowns.value += 1 },
      readinessChecker: { _ in true },
      requireRoot: false)
    try legacyManager.install(
      executableURL: fixture.source, user: String(geteuid()))

    let legacyPlistURL = URL(fileURLWithPath: legacyLayout.plistPath)
    var markedPlist = try String(contentsOf: legacyPlistURL, encoding: .utf8)
    markedPlist = markedPlist.replacingOccurrences(
      of: "<plist version=\"1.0\">",
      with: "<!-- preserve this legacy plist byte-for-byte -->\n<plist version=\"1.0\">")
    try Data(markedPlist.utf8).write(to: legacyPlistURL)
    XCTAssertEqual(chmod(legacyLayout.plistPath, 0o644), 0)
    XCTAssertEqual(chown(legacyLayout.plistPath, geteuid(), getegid()), 0)
    let markedConfig = Data(
      "{ \"allowedUID\" : \(geteuid()), \"version\" : 1 }\n".utf8)
    try markedConfig.write(to: URL(fileURLWithPath: legacyLayout.configPath))
    XCTAssertEqual(chmod(legacyLayout.configPath, 0o600), 0)
    XCTAssertEqual(chown(legacyLayout.configPath, geteuid(), getegid()), 0)

    let legacyExecutable = try Data(
      contentsOf: URL(fileURLWithPath: legacyLayout.executablePath))
    let legacyPlist = try Data(contentsOf: legacyPlistURL)
    let legacyConfig = try Data(contentsOf: URL(fileURLWithPath: legacyLayout.configPath))
    let replacement = fixture.root.appendingPathComponent("replacement-daemon")
    try Data("replacement-must-not-become-legacy".utf8).write(to: replacement)
    XCTAssertEqual(chmod(replacement.path, 0o755), 0)

    runner.calls.removeAll()
    readinessChecks = 0
    runner.results = [
      CommandResult(status: 0),
      CommandResult(status: 17, stderr: "new identity bootstrap failed"),
      CommandResult(status: 0),
      CommandResult(status: 0),
    ]
    let currentManager = DaemonManager(
      layout: fixture.layout,
      commandRunner: runner,
      shutdownRequester: { _ in shutdowns.value += 1 },
      readinessChecker: { _ in
        readinessChecks += 1
        return true
      },
      requireRoot: false)

    XCTAssertThrowsError(
      try currentManager.installReplacingLegacy(
        executableURL: replacement, legacyLayout: legacyLayout, environment: [:])
    ) {
      guard case .commandFailed = ($0 as? DaemonManagementError) else {
        return XCTFail("expected original bootstrap error, got \($0)")
      }
    }

    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: legacyLayout.executablePath)),
      legacyExecutable)
    XCTAssertEqual(try Data(contentsOf: legacyPlistURL), legacyPlist)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: legacyLayout.configPath)), legacyConfig)
    for (path, expectedMode) in [
      (legacyLayout.executablePath, mode_t(0o755)),
      (legacyLayout.plistPath, mode_t(0o644)),
      (legacyLayout.configPath, mode_t(0o600)),
    ] {
      var info = stat()
      XCTAssertEqual(lstat(path, &info), 0)
      XCTAssertEqual(info.st_mode & 0o7777, expectedMode)
      XCTAssertEqual(info.st_uid, geteuid())
      XCTAssertEqual(info.st_gid, getegid())
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.executablePath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.plistPath))
    XCTAssertEqual(readinessChecks, 1, "restored legacy service must pass readiness")
    XCTAssertEqual(
      runner.calls.map(\.arguments),
      [
        ["bootout", legacyLayout.serviceTarget],
        ["bootstrap", "system", fixture.layout.plistPath],
        ["bootout", fixture.layout.serviceTarget],
        ["bootstrap", "system", legacyLayout.plistPath],
      ])
  }

  func testLegacyMigrationSerializesConcurrentLifecycleOperations() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let legacyLayout = legacyLayout(for: fixture)
    let runner = BlockingRunner()
    let legacyManager = DaemonManager(
      layout: legacyLayout,
      commandRunner: runner,
      shutdownRequester: { _ in },
      readinessChecker: { _ in true },
      requireRoot: false)
    try legacyManager.install(
      executableURL: fixture.source, user: String(geteuid()))
    runner.resetAndBlockNextBootout()

    let currentManager = DaemonManager(
      layout: fixture.layout,
      commandRunner: runner,
      shutdownRequester: { _ in },
      readinessChecker: { _ in true },
      requireRoot: false)
    let migrationError = ErrorBox()
    let lifecycleError = ErrorBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      migrationError.capture {
        try currentManager.installReplacingLegacy(
          executableURL: fixture.source, legacyLayout: legacyLayout, environment: [:])
      }
    }
    XCTAssertTrue(runner.waitUntilBootoutIsBlocked(timeout: 2))

    let lifecycleStarted = DispatchSemaphore(value: 0)
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      lifecycleStarted.signal()
      lifecycleError.capture { try currentManager.start() }
    }
    XCTAssertEqual(lifecycleStarted.wait(timeout: .now() + 1), .success)
    usleep(100_000)
    XCTAssertEqual(
      runner.callCount, 1,
      "a concurrent lifecycle command must not enter launchctl during migration")

    runner.releaseBlockedBootout()
    XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
    XCTAssertNil(migrationError.error)
    XCTAssertNil(lifecycleError.error)
    XCTAssertEqual(runner.callCount, 3)
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
