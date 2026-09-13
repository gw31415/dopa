import Foundation
@testable import DopaUI
import XCTest

final class DaemonInstallerTests: XCTestCase {
  func testInstalledRequiresSecureManagedFilesAndRejectsSymlinks() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let installer = fixture.installer()
    XCTAssertFalse(installer.isInstalled)

    try fixture.createManagedFiles()
    XCTAssertTrue(installer.isInstalled)

    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.plist.path)
    XCTAssertFalse(installer.isInstalled)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.plist.path)
    XCTAssertTrue(installer.isInstalled)

    try FileManager.default.removeItem(at: fixture.executable)
    try FileManager.default.createSymbolicLink(
      at: fixture.executable, withDestinationURL: fixture.plist)
    XCTAssertFalse(installer.isInstalled)
  }

  func testInstallUsesBundledDaemonAndExplicitUserOnlyWhenCalled() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.createBundledDaemon()
    let capture = CommandCapture()
    let installer = fixture.installer(userID: 502) { command in
      await capture.record(command)
      return .init(status: 0, standardError: "")
    }

    let valueBeforeInstall = await capture.value
    XCTAssertNil(valueBeforeInstall)
    try await installer.install()
    let capturedCommand = await capture.value
    let command = try XCTUnwrap(capturedCommand)
    XCTAssertTrue(command.contains(" install --user 502"))
    XCTAssertTrue(command.contains("Contents/Helpers/dopa-daemon"))
    XCTAssertTrue(command.contains("shasum -a 256"))
    XCTAssertTrue(command.contains("codesign --verify --strict"))
    XCTAssertFalse(command.contains("/private/tmp"))
  }

  func testInstallReportsElevationFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.createBundledDaemon()
    let installer = fixture.installer { _ in .init(status: 1, standardError: "認証がキャンセルされました\n") }

    do {
      try await installer.install()
      XCTFail("expected installation failure")
    } catch let error as DaemonInstallerError {
      XCTAssertEqual(error, .authorizationFailed("認証がキャンセルされました"))
    }
  }

  func testCancelledInstallDoesNotBeginElevation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.createBundledDaemon()
    let capture = CommandCapture()
    let installer = fixture.installer { command in
      await capture.record(command)
      return .init(status: 0, standardError: "")
    }

    let task = Task { try await installer.install() }
    task.cancel()
    do {
      try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {}
    let capturedCommand = await capture.value
    XCTAssertNil(capturedCommand)
  }

  func testInstalledServiceManagementUsesRequestedCommand() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.createManagedFiles()
    try fixture.createBundledDaemon()
    let capture = CommandCapture()
    let installer = fixture.installer { command in
      await capture.record(command)
      return .init(status: 0, standardError: "")
    }

    try await installer.manage(.start)
    let captured = await capture.capturedValue()
    let command = try XCTUnwrap(captured)
    XCTAssertTrue(command.contains("PrivilegedHelperTools/dev.amas.dopa.daemon"))
    XCTAssertTrue(command.hasSuffix(" start"))
  }
}

private actor CommandCapture {
  private(set) var value: String?
  func record(_ value: String) { self.value = value }
  func capturedValue() -> String? { value }
}

private struct Fixture {
  let root: URL
  let bundle: URL
  let plist: URL
  let executable: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dopa-installer-tests-\(UUID().uuidString)")
    bundle = root.appendingPathComponent("Dopa.app")
    plist = root.appendingPathComponent("LaunchDaemons/dev.amas.dopa.daemon.plist")
    executable = root.appendingPathComponent("PrivilegedHelperTools/dev.amas.dopa.daemon")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func installer(
    userID: UInt32 = 501,
    runner: @escaping DaemonInstaller.ElevatedRunner = { _ in .init(status: 0, standardError: "") }
  ) -> DaemonInstaller {
    DaemonInstaller(
      layout: .init(
        plistURL: plist, executableURL: executable,
        ownerUID: geteuid(), ownerGID: getegid()),
      bundleURL: bundle, userID: userID, runElevated: runner)
  }

  func createManagedFiles() throws {
    for url in [plist, executable] {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("fixture".utf8)))
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
  }

  func createBundledDaemon() throws {
    let daemon = bundle.appendingPathComponent("Contents/Helpers/dopa-daemon")
    try FileManager.default.createDirectory(
      at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: daemon.path, contents: Data("fixture".utf8)))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
