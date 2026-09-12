import Darwin
import Dispatch
import DopaClient
import DopaProtocol
import Foundation

private struct Options: Equatable, Sendable {
  var keepDisplayOn = false
  var stopOnLidClose = false

  static let help = """
    dopa — keep your Mac awake

    Usage: dopa [OPTIONS]

      -d, --keep-display-on     Prevent idle display sleep (default: off)
      -l, --stop-on-lid-close   End this session when the lid closes
                               (default: off; also exits if already closed)
      -h, --help                Print help; no daemon connection required

    Without options, keep the system awake even with the lid closed.
    Ctrl+C ends this session. The original sleep setting is restored after
    the last session ends.
    """

  static func parse(_ arguments: [String]) throws -> Options? {
    var options = Options()
    var endedOptions = false
    for argument in arguments {
      if endedOptions {
        throw CLIError("unknown argument: \(argument); use dopa --help", status: 2)
      }
      switch argument {
      case "--":
        endedOptions = true
      case "--keep-display-on":
        options.keepDisplayOn = true
      case "--stop-on-lid-close":
        options.stopOnLidClose = true
      case "--help":
        return nil
      case let group where group.hasPrefix("-") && !group.hasPrefix("--"):
        let flags = group.utf8.dropFirst()
        guard !flags.isEmpty else {
          throw CLIError("unknown argument: \(argument); use dopa --help", status: 2)
        }
        for flag in flags {
          switch flag {
          case UInt8(ascii: "d"):
            options.keepDisplayOn = true
          case UInt8(ascii: "l"):
            options.stopOnLidClose = true
          case UInt8(ascii: "h"):
            return nil
          default:
            throw CLIError("unknown argument: \(argument); use dopa --help", status: 2)
          }
        }
      default:
        throw CLIError("unknown argument: \(argument); use dopa --help", status: 2)
      }
    }
    return options
  }
}

private struct CLIError: Error, CustomStringConvertible {
  let description: String
  let status: Int32

  init(_ description: String, status: Int32 = 1) {
    self.description = description
    self.status = status
  }
}

private final class SignalState: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func requestStop() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var requested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private func installSignalSources(state: SignalState) -> [DispatchSourceSignal] {
  [SIGINT, SIGTERM, SIGHUP, SIGQUIT].map { signalNumber in
    // Ignore the default action before creating the dispatch source. The
    // source then receives the signal without terminating the CLI in the
    // middle of the release request.
    _ = Darwin.signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler { state.requestStop() }
    source.resume()
    return source
  }
}

private func release(
  connection: DopaConnection, sessionID: String
) throws {
  _ = try connection.request(
    method: "session.release",
    params: .object(["sessionId": .string(sessionID)]),
    timeout: 10)
}

private func writeError(_ message: String) {
  try? FileHandle.standardError.write(contentsOf: Data("dopa: \(message)\n".utf8))
}

private func runSession(_ options: Options) throws {
  let signalState = SignalState()
  let signalSources = installSignalSources(state: signalState)
  defer {
    for source in signalSources { source.cancel() }
    for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
      _ = Darwin.signal(signalNumber, SIG_DFL)
    }
  }

  let connection: DopaConnection
  do {
    connection = try DopaConnection(clientName: "dopa")
  } catch {
    throw CLIError(
      "cannot connect to dopa-daemon: \(error); run sudo dopa-daemon install",
      status: 1)
  }
  defer { connection.close() }

  // A signal received while hello was in flight means the user cancelled the
  // invocation. Do not create a new session after that cancellation.
  guard !signalState.requested else { return }

  let acquire: JSONValue
  do {
    acquire = try connection.request(
      method: "session.acquire",
      params: .object([
        "options": .object([
          "keepDisplayOn": .bool(options.keepDisplayOn),
          "stopOnLidClose": .bool(options.stopOnLidClose),
        ])
      ]),
      timeout: 10)
  } catch {
    throw CLIError("cannot start sleep inhibition: \(error)", status: 1)
  }
  guard let sessionID = acquire["sessionId"]?.stringValue, !sessionID.isEmpty else {
    throw CLIError("dopa-daemon returned an invalid session", status: 1)
  }

  writeError("sleep inhibition active; press Ctrl+C to release")
  while true {
    if signalState.requested {
      do {
        try release(connection: connection, sessionID: sessionID)
        return
      } catch {
        throw CLIError("could not confirm session release: \(error)", status: 1)
      }
    }

    do {
      guard let event = try connection.receive(timeout: 0.2) else { continue }
      guard event["event"]?.stringValue == "session.ended" else { continue }
      guard event["data"]?["sessionId"]?.stringValue == sessionID else { continue }
      guard event["data"]?["cleanup"]?.stringValue == "confirmed" else {
        throw CLIError("dopa-daemon ended the session without confirming cleanup", status: 1)
      }
      let reason = event["data"]?["reason"]?.stringValue ?? "unknown"
      if reason == "lid_closed" || reason == "daemon_shutdown" { return }
      throw CLIError("dopa-daemon ended the session (\(reason))", status: 1)
    } catch let error as CLIError {
      throw error
    } catch {
      throw CLIError("dopa-daemon connection failed: \(error)", status: 1)
    }
  }
}

private func run() throws {
  guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    print(Options.help)
    return
  }
  try runSession(options)
}

do {
  try run()
} catch let error as CLIError {
  writeError(error.description)
  exit(error.status)
} catch {
  writeError(String(describing: error))
  exit(1)
}
