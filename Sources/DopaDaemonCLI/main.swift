import Darwin
import DopaClient
import DopaCore
import DopaManagement
import DopaProtocol
import Foundation

private enum DaemonCommand {
  case help
  case install(user: String?)
  case uninstall
  case start
  case stop
  case restart
  case status(json: Bool)
  case run
}

private struct DaemonCLIError: Error, CustomStringConvertible {
  let description: String
  let status: Int32

  init(_ description: String, status: Int32 = 2) {
    self.description = description
    self.status = status
  }
}

private let daemonHelp = """
  dopa-daemon — privileged Dopa service

  Usage:
    sudo dopa-daemon install [--user NAME|UID]
    sudo dopa-daemon uninstall
    sudo dopa-daemon start
    sudo dopa-daemon stop
    sudo dopa-daemon restart
    dopa-daemon status [--json]
    sudo dopa-daemon run

  Commands:
    install       Install or update the launchd-managed daemon.
    uninstall     Stop the daemon and remove its managed files.
    start         Start an installed daemon and wait until it is ready.
    stop          Restore active sessions and stop the daemon safely.
    restart       Safely stop, start, and verify the daemon.
    status        Show the daemon snapshot; --json emits one JSON object.
    run           Run the foreground launchd service.

  install preserves the configured user during updates. Use uninstall followed
  by install --user to change it. Updating or uninstalling ends active sessions.
  install, uninstall, start, stop, restart, and run require root.
  """

private func parse(_ args: [String]) throws -> DaemonCommand {
  guard let command = args.first else { return .help }
  if command == "--help" || command == "-h" { return .help }

  switch command {
  case "install":
    var user: String?
    var index = 1
    while index < args.count {
      switch args[index] {
      case "--help", "-h": return .help
      case "--user":
        guard user == nil, index + 1 < args.count else {
          throw DaemonCLIError("install --user requires exactly one account name or UID")
        }
        index += 1
        user = args[index]
      case let value where value.hasPrefix("--user="):
        guard user == nil else { throw DaemonCLIError("install accepts only one --user") }
        let value = String(value.dropFirst("--user=".count))
        guard !value.isEmpty else { throw DaemonCLIError("install --user cannot be empty") }
        user = value
      default:
        throw DaemonCLIError("unknown install argument: \(args[index])")
      }
      index += 1
    }
    return .install(user: user)

  case "uninstall":
    if args.count == 1 { return .uninstall }
    if args.dropFirst().allSatisfy({ $0 == "--help" || $0 == "-h" }) { return .help }
    throw DaemonCLIError("uninstall does not accept arguments")

  case "start":
    if args.count == 1 { return .start }
    if args.dropFirst().allSatisfy({ $0 == "--help" || $0 == "-h" }) { return .help }
    throw DaemonCLIError("start does not accept arguments")

  case "stop":
    if args.count == 1 { return .stop }
    if args.dropFirst().allSatisfy({ $0 == "--help" || $0 == "-h" }) { return .help }
    throw DaemonCLIError("stop does not accept arguments")

  case "restart":
    if args.count == 1 { return .restart }
    if args.dropFirst().allSatisfy({ $0 == "--help" || $0 == "-h" }) { return .help }
    throw DaemonCLIError("restart does not accept arguments")

  case "status":
    var json = false
    for argument in args.dropFirst() {
      switch argument {
      case "--help", "-h": return .help
      case "--json":
        guard !json else { throw DaemonCLIError("status accepts only one --json") }
        json = true
      default: throw DaemonCLIError("unknown status argument: \(argument)")
      }
    }
    return .status(json: json)

  case "run":
    if args.count > 1 {
      if args.dropFirst().allSatisfy({ $0 == "--help" || $0 == "-h" }) { return .help }
      throw DaemonCLIError("run does not accept arguments")
    }
    return .run

  default:
    throw DaemonCLIError("unknown command: \(command); use dopa-daemon --help")
  }
}

private func requireRoot(for command: String) throws {
  guard geteuid() == 0 else {
    throw DaemonCLIError(
      "root is required for dopa-daemon \(command); run sudo dopa-daemon \(command)", status: 1)
  }
}

private func executableURL() throws -> URL {
  if let executable = Bundle.main.executableURL { return executable }
  let argument = CommandLine.arguments.first ?? ""
  guard !argument.isEmpty else { throw DaemonCLIError("cannot locate dopa-daemon executable", status: 1) }
  let url = URL(fileURLWithPath: argument, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
  return url.standardizedFileURL
}

private func runStatus(json: Bool) throws {
  let connection: DopaConnection
  do {
    connection = try DopaConnection(
      path: DaemonLayout.system.socketPath, requireRoot: true, clientName: "dopa-daemon")
  } catch {
    throw DaemonCLIError("cannot connect to dopa-daemon: \(error)", status: 1)
  }
  defer { connection.close() }
  let snapshot: JSONValue
  do {
    snapshot = try connection.request(method: "status.get", params: .object([:]))
  } catch {
    throw DaemonCLIError("cannot read daemon status: \(error)", status: 1)
  }
  if json {
    do {
      print(try DaemonStatusFormatter.json(snapshot))
    } catch {
      throw DaemonCLIError("cannot encode daemon status: \(error)", status: 1)
    }
  } else {
    print(DaemonStatusFormatter.human(snapshot))
  }

  if snapshot["phase"]?.stringValue == "degraded" {
    throw DaemonCLIError("daemon is degraded", status: 1)
  }
}

private func run() throws {
  let command = try parse(Array(CommandLine.arguments.dropFirst()))
  switch command {
  case .help:
    print(daemonHelp)

  case .install(let user):
    try requireRoot(for: "install")
    let manager = DaemonManager()
    do {
      try manager.installReplacingLegacy(executableURL: try executableURL(), user: user)
    } catch {
      throw DaemonCLIError("install failed: \(error)", status: 1)
    }
    print("dopa-daemon installed and ready")

  case .uninstall:
    try requireRoot(for: "uninstall")
    do {
      try DaemonManager().uninstall()
    } catch {
      throw DaemonCLIError("uninstall failed: \(error)", status: 1)
    }
    print("dopa-daemon uninstalled")

  case .start:
    try requireRoot(for: "start")
    do {
      try DaemonManager().start()
    } catch {
      throw DaemonCLIError("start failed: \(error)", status: 1)
    }
    print("dopa-daemon started and ready")

  case .stop:
    try requireRoot(for: "stop")
    do {
      try DaemonManager().stop()
    } catch {
      throw DaemonCLIError("stop failed: \(error)", status: 1)
    }
    print("dopa-daemon stopped")

  case .restart:
    try requireRoot(for: "restart")
    do {
      try DaemonManager().restart()
    } catch {
      throw DaemonCLIError("restart failed: \(error)", status: 1)
    }
    print("dopa-daemon restarted and ready")

  case .status(let json):
    try runStatus(json: json)

  case .run:
    try requireRoot(for: "run")
    let configuration: DaemonConfiguration
    do {
      configuration = try DaemonConfiguration.loadSecure(
        from: DaemonLayout.system.configPath, ownerUID: 0, groupGID: 0, mode: 0o600)
    } catch {
      throw DaemonCLIError(
        "cannot load daemon configuration; run sudo dopa-daemon install: \(error)", status: 1)
    }
    do {
      try Runtime.installSignals()
      try DaemonService.run(
        statePath: DaemonLayout.system.statePath,
        socketPath: DaemonLayout.system.socketPath,
        allowedUID: configuration.allowedUID,
        power: NativePower(),
        controls: NativeControls(),
        requireRoot: true)
    } catch {
      throw DaemonCLIError("daemon stopped: \(error)", status: 1)
    }
  }
}

do {
  try run()
} catch let error as DaemonCLIError {
  log(error.description)
  exit(error.status)
} catch {
  log(String(describing: error))
  exit(1)
}
