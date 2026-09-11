// This executable is a test fixture, not part of the distributed dopa binary.
import Darwin
import DopaCore
import Foundation

final class FilePower: Power {
  let directory: URL
  init(_ directory: URL) { self.directory = directory }
  func readDisabled() throws -> Bool {
    try String(contentsOf: directory.appendingPathComponent("power"), encoding: .utf8) == "1"
  }
  func setDisabled(_ disabled: Bool) throws {
    if disabled
      && FileManager.default.fileExists(atPath: directory.appendingPathComponent("delay").path)
    {
      try "1".write(
        to: directory.appendingPathComponent("enabling"), atomically: true, encoding: .utf8)
      usleep(500_000)
    }
    try (disabled ? "1" : "0").write(
      to: directory.appendingPathComponent("power"), atomically: true, encoding: .utf8)
  }
}
final class FileControls: Controls {
  let directory: URL
  init(_ directory: URL) { self.directory = directory }
  func keepDisplayOn() throws {
    try "1".write(
      to: directory.appendingPathComponent("display"), atomically: true, encoding: .utf8)
  }
  func releaseDisplay() throws {
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("display").path) {
      try "0".write(
        to: directory.appendingPathComponent("display"), atomically: true, encoding: .utf8)
    }
  }
  func lidClosed() throws -> Bool {
    switch try String(contentsOf: directory.appendingPathComponent("lid"), encoding: .utf8) {
    case "0": return false
    case "1": return true
    default: throw DopaError("injected lid failure")
    }
  }
}

do {
  let env = ProcessInfo.processInfo.environment
  if CommandLine.arguments.contains("--native-probe") {
    let power = NativePower()
    let controls = NativeControls()
    print("SleepDisabled=\(try power.readDisabled()), lidClosed=\(try controls.lidClosed())")
    try controls.keepDisplayOn()
    print("display assertion active; pid=\(getpid())")
    fflush(stdout)
    usleep(500_000)
    try controls.releaseDisplay()
    print("display assertion released")
  } else {
    guard let path = env["DOPA_TEST_DIRECTORY"] else { throw DopaError("missing test directory") }
    let directory = URL(fileURLWithPath: path)
    let options = Options(
      keepDisplayOn: env["DOPA_TEST_DISPLAY"] == "1", stopOnLidClose: env["DOPA_TEST_LID"] == "1")
    try Runtime.installSignals()
    if env["DOPA_TEST_CHILD"] == "1" {
      try Runtime.guardian(
        channel: Runtime.inheritedChannel(), path: directory.appendingPathComponent("state").path,
        power: FilePower(directory), controls: FileControls(directory), options: options)
    } else {
      var childEnv = env
      childEnv["DOPA_TEST_CHILD"] = "1"
      try Runtime.frontend(
        executable: Bundle.main.executableURL!, arguments: [], environment: childEnv)
    }
  }
} catch {
  log(String(describing: error))
  exit(1)
}
