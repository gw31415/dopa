import Darwin
import Dispatch
import DopaClient
import DopaLid
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
  private var notifyDescriptor: Int32

  init(notifyDescriptor: Int32) {
    self.notifyDescriptor = notifyDescriptor
  }

  func requestStop() {
    lock.lock()
    value = true
    if notifyDescriptor >= 0 {
      var byte: UInt8 = 1
      while Darwin.write(notifyDescriptor, &byte, 1) < 0 {
        if errno == EINTR { continue }
        // EAGAIN means a wake byte is already pending. The boolean remains
        // authoritative for every other failure as well.
        break
      }
    }
    lock.unlock()
  }

  var requested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func retireNotificationDescriptor() {
    lock.lock()
    let descriptor = notifyDescriptor
    notifyDescriptor = -1
    if descriptor >= 0 { Darwin.close(descriptor) }
    lock.unlock()
  }
}

private func installSignalSources(state: SignalState) -> [DispatchSourceSignal] {
  [SIGINT, SIGTERM, SIGHUP, SIGQUIT].map { signalNumber in
    // Ignore the default action before creating the dispatch source. The
    // source then receives the signal without terminating the CLI in the
    // middle of the release request.
    _ = Darwin.signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    // This handler runs on a dispatch queue, not in async-signal context.
    // SignalState serializes write-end retirement with every notification, so
    // a late cancelled handler cannot write to a closed or reused descriptor.
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

/// Consumes one event if it is already queued or arrives within `timeout`.
/// `nil` means there was no event, `false` means an unrelated event was
/// consumed, and `true` means this session ended successfully.
private func receiveSessionEvent(
  connection: DopaConnection, sessionID: String, timeout: TimeInterval
) throws -> Bool? {
  guard let event = try connection.receive(timeout: timeout) else { return nil }
  guard event["event"]?.stringValue == "session.ended" else { return false }
  guard event["data"]?["sessionId"]?.stringValue == sessionID else { return false }
  guard event["data"]?["cleanup"]?.stringValue == "confirmed" else {
    throw CLIError("dopa-daemon ended the session without confirming cleanup", status: 1)
  }
  let reason = event["data"]?["reason"]?.stringValue ?? "unknown"
  if reason == "daemon_shutdown" || reason == "user_stopped" {
    return true
  }
  throw CLIError("dopa-daemon ended the session (\(reason))", status: 1)
}

private func runSession(
  _ options: Options, lidState: any LidStateReading = NativeLidState()
) throws {
  if options.stopOnLidClose {
    do {
      if try lidState.isClosed() { return }
    } catch {
      throw CLIError("cannot read lid state: \(error)", status: 1)
    }
  }

  // Signal pipe: lets the loop below wait on the daemon socket and stop
  // notifications together instead of polling on a fixed cadence. Both ends
  // are close-on-exec; the read end is non-blocking so draining never stalls.
  var pipeFDs = [Int32](repeating: -1, count: 2)
  guard pipeFDs.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
    throw CLIError("cannot create signal pipe: \(String(cString: strerror(errno)))", status: 1)
  }
  for fd in pipeFDs {
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
      for open in pipeFDs where open >= 0 { Darwin.close(open) }
      throw CLIError("cannot configure signal pipe: \(String(cString: strerror(errno)))", status: 1)
    }
  }
  let signalState = SignalState(notifyDescriptor: pipeFDs[1])
  let signalSources = installSignalSources(state: signalState)
  defer {
    for source in signalSources { source.cancel() }
    for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
      _ = Darwin.signal(signalNumber, SIG_DFL)
    }
    // Retire the write end under the same lock used by event handlers before
    // closing the read end. This also avoids SIGPIPE and descriptor reuse if a
    // cancellation races a queued signal delivery.
    signalState.retireNotificationDescriptor()
    Darwin.close(pipeFDs[0])
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
          "keepDisplayOn": .bool(options.keepDisplayOn)
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
  var pipeByte: UInt8 = 0
  var nextLidCheck = DispatchTime.now().uptimeNanoseconds + 300_000_000
  do {
    while true {
      if signalState.requested {
        do {
          try release(connection: connection, sessionID: sessionID)
          return
        } catch {
          throw CLIError("could not confirm session release: \(error)", status: 1)
        }
      }

      if options.stopOnLidClose,
        DispatchTime.now().uptimeNanoseconds >= nextLidCheck
      {
        do {
          if try lidState.isClosed() {
            do {
              try release(connection: connection, sessionID: sessionID)
              return
            } catch {
              throw CLIError("could not confirm session release after the lid closed: \(error)", status: 1)
            }
          }
        } catch let error as CLIError {
          throw error
        } catch {
          let lidError = error
          do {
            try release(connection: connection, sessionID: sessionID)
          } catch {
            throw CLIError(
              "cannot read lid state (\(lidError)); could not confirm session release: \(error)",
              status: 1)
          }
          throw CLIError("cannot read lid state; session released: \(lidError)", status: 1)
        }
        nextLidCheck = DispatchTime.now().uptimeNanoseconds + 300_000_000
      }

      // A request can decode its response and a following event from one
      // socket read. Drain that client-side queue before waiting on the
      // kernel descriptor, which may already be empty in that case.
      if let ended = try receiveSessionEvent(
        connection: connection, sessionID: sessionID, timeout: 0)
      {
        if ended { return }
        continue
      }

      // Wait for daemon traffic or a stop notification together. Either one
      // wakes the loop immediately; the signal flag is rechecked at the top.
      var items = [
        Darwin.pollfd(fd: connection.socketDescriptor, events: Int16(POLLIN), revents: 0),
        Darwin.pollfd(fd: pipeFDs[0], events: Int16(POLLIN), revents: 0),
      ]
      let timeout: Int32
      if options.stopOnLidClose {
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = nextLidCheck > now ? nextLidCheck - now : 0
        timeout = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
      } else {
        timeout = -1
      }
      let ready = Darwin.poll(&items, nfds_t(items.count), timeout)
      if ready < 0 {
        if errno == EINTR { continue }
        throw CLIError(
          "dopa-daemon connection failed: \(String(cString: strerror(errno)))", status: 1)
      }
      if ready == 0 { continue }
      if items[1].revents & Int16(POLLIN) != 0 {
        while Darwin.read(pipeFDs[0], &pipeByte, 1) > 0 {}
        continue
      }
      guard items[0].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 else {
        continue
      }
      // The socket reported activity, so this returns promptly; the bound
      // only caps a spurious wakeup, matching the previous tick length.
      if try receiveSessionEvent(connection: connection, sessionID: sessionID, timeout: 0.2) == true {
        return
      }
    }
  } catch let error as CLIError {
    throw error
  } catch {
    throw CLIError("dopa-daemon connection failed: \(error)", status: 1)
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
