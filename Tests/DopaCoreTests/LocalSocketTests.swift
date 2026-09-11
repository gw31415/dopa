import Darwin
import Foundation
import XCTest

@testable import DopaCore

final class LocalSocketTests: XCTestCase {
  private func makeDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(
      "dopa-socket-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  func testListenAndConnectRefuseRegularFileAndSymlink() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state").path
    let state = try State(path: path)
    let socket = directory.appendingPathComponent("state/control.sock")
    let victim = directory.appendingPathComponent("victim")
    try Data("not a socket".utf8).write(to: socket)

    XCTAssertThrowsError(try LocalSocket.listen(state: state)) {
      XCTAssertTrue(String(describing: $0).contains("unsafe control socket"))
    }
    XCTAssertThrowsError(try LocalSocket.connect(path: path)) {
      XCTAssertTrue(String(describing: $0).contains("unsafe control socket"))
    }

    try FileManager.default.removeItem(at: socket)
    try Data("victim".utf8).write(to: victim)
    try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: victim)
    XCTAssertThrowsError(try LocalSocket.listen(state: state)) {
      XCTAssertTrue(String(describing: $0).contains("unsafe control socket"))
    }
    XCTAssertThrowsError(try LocalSocket.connect(path: path)) {
      XCTAssertTrue(String(describing: $0).contains("unsafe control socket"))
    }
  }

  func testStateElectionSocketPermissionsAndPeerValidation() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state").path
    let state = try State(path: path)
    XCTAssertThrowsError(try State(path: path)) { XCTAssertTrue($0 is State.InUse) }
    let listener = try LocalSocket.listen(state: state)
    defer { try? LocalSocket.remove(state: state) }

    var info = stat()
    XCTAssertEqual(stat(path + "/control.sock", &info), 0)
    XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertEqual(info.st_uid, geteuid())

    guard let client = try LocalSocket.connect(path: path) else {
      return XCTFail("listener socket was not connectable")
    }
    guard let accepted = try LocalSocket.accept(listener: listener.value) else {
      return XCTFail("listener did not accept the local client")
    }
    XCTAssertEqual(try LocalSocket.peerPID(accepted.value), getpid())
    _ = client
    _ = accepted
  }
}
