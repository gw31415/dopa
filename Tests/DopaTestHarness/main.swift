// This executable is a test fixture, not part of the distributed dopa binary.
import Darwin
import DopaCore
import Foundation

final class FilePower: Power {
  let directory: URL
  init(_ directory: URL) { self.directory = directory }
  private func write(_ name: String, _ value: String) throws {
    try value.write(
      to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  func readDisabled() throws -> Bool {
    try String(contentsOf: directory.appendingPathComponent("power"), encoding: .utf8) == "1"
  }
  func setDisabled(_ disabled: Bool) throws {
    if disabled {
      let session = "\(getsid(0)) \(getpid())"
      try write("guardian-session", session)
      try write("guardian-session-\(getpid())", session)
      try write("enable-\(getpid())-\(UUID().uuidString)", "1")
    } else {
      try write("restore-\(getpid())-\(UUID().uuidString)", "1")
    }
    if !disabled
      && FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("delay-restore").path)
    {
      try write("restoring", "1")
      usleep(500_000)
    }
    if disabled
      && FileManager.default.fileExists(atPath: directory.appendingPathComponent("delay").path)
    {
      try write("enabling", "1")
      usleep(500_000)
    }
    try write("power", disabled ? "1" : "0")
  }
}
final class FileControls: DisplayControls {
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
}

do {
  let env = ProcessInfo.processInfo.environment
  if CommandLine.arguments.contains("--native-probe") {
    let power = NativePower()
    let controls = NativeDisplayControls()
    print("SleepDisabled=\(try power.readDisabled())")
    try controls.keepDisplayOn()
    print("display assertion active; pid=\(getpid())")
    fflush(stdout)
    usleep(500_000)
    try controls.releaseDisplay()
    print("display assertion released")
  } else {
    guard let path = env["DOPA_TEST_DIRECTORY"] else { throw DopaError("missing test directory") }
    let directory = URL(fileURLWithPath: path)
    try Runtime.installSignals()
    if env["DOPA_TEST_DAEMON"] == "1" {
      // Only this explicit test executable accepts a dummy authorization.
      // The production daemon always uses macOS Authorization Services.
      let authorizationVerifier: ((Data) -> Bool)? = env["DOPA_TEST_ADMIN_AUTH"] == "1"
        ? { $0 == Data(repeating: 0xAB, count: 32) } : nil
      try DaemonService.run(
        statePath: directory.appendingPathComponent("state").path,
        socketPath: directory.appendingPathComponent("ipc/control.sock").path,
        allowedUID: env["DOPA_TEST_ALLOWED_UID"].flatMap(UInt32.init) ?? geteuid(),
        power: FilePower(directory), controls: FileControls(directory),
        requireRoot: false, authorizationVerifier: authorizationVerifier)
    } else if env["DOPA_TEST_CHILD"] == "1" {
      try "\(getsid(0))\n\(getpid())\n".write(
        to: directory.appendingPathComponent("guardian-session"), atomically: true, encoding: .utf8)
      try Runtime.guardian(
        path: directory.appendingPathComponent("state").path,
        power: FilePower(directory), controls: FileControls(directory))
    } else {
      let options = Options(keepDisplayOn: env["DOPA_TEST_DISPLAY"] == "1")
      var childEnv = env
      childEnv["DOPA_TEST_CHILD"] = "1"
      try Runtime.frontend(
        executable: Bundle.main.executableURL!, environment: childEnv, options: options,
        path: directory.appendingPathComponent("state").path)
    }
  }
} catch {
  log(String(describing: error))
  exit(1)
}
