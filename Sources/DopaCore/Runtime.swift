import CDopa
import Darwin
import Foundation

public enum Runtime {
  public static func installSignals() throws {
    guard dopa_install_signals() == 0 else { throw systemError("install signal handlers") }
  }

  public static func frontend(
    executable: URL, environment: [String: String], options: Options,
    path: String = "/var/db/dopa"
  ) throws {
    let directory = try State.prepareDirectory(path: path)
    defer { withExtendedLifetime(directory) {} }
    var child: pid_t?
    // A shared guardian can outlive the frontend that started it. Reap it if
    // finished; otherwise normal CLI exit reparents it without killing it.
    defer {
      if let child {
        var status: Int32 = 0
        _ = dopa_poll_guardian(child, &status)
      }
    }
    var everReady = false
    var nextSpawn: UInt64 = 0
    var deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    while dopa_stop_requested() == 0 {
      if let channel = try LocalSocket.connect(path: path) {
        defer { withExtendedLifetime(channel) {} }
        if try participate(
          channel: channel.value, options: options, everReady: &everReady, child: &child)
        {
          return
        }
        // A coordinator can finish while a new connection is still queued, or
        // crash while serving us. Rejoin through the same startup election.
        log("guardian disconnected; reconnecting")
        deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
      }
      if let pid = child {
        var status: Int32 = 0
        let result = dopa_poll_guardian(pid, &status)
        guard result >= 0 else { throw systemError("reap guardian") }
        if result == 1 {
          child = nil
          if status != 0 && !everReady {
            throw DopaError("guardian startup failed (status \(status))")
          }
        }
      }
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { throw DopaError("timed out connecting to guardian") }
      if child == nil, now >= nextSpawn {
        child = try spawn(executable: executable, environment: environment)
        nextSpawn = now + 500_000_000
      }
      // Only startup/reconnection uses retries. A registered client waits on
      // its live socket and signals until its own session has been released.
      _ = poll(nil, 0, 50)
    }
  }

  private static func participate(
    channel: Int32, options: Options, everReady: inout Bool, child: inout pid_t?
  )
    throws -> Bool
  {
    defer { _ = shutdown(channel, SHUT_RDWR) }
    let registration: UInt8 =
      0xA0 | (options.keepDisplayOn ? 1 : 0)
      | (options.stopOnLidClose ? 2 : 0)
    guard Wire.send(registration, to: channel) else { return false }
    var ready = false
    var stopping = false
    while true {
      // A losing election candidate may exit after we connect to the winner.
      // Reap it during the session instead of keeping a zombie until exit.
      if let pid = child {
        var status: Int32 = 0
        let result = dopa_poll_guardian(pid, &status)
        if result == 1 || (result < 0 && errno == ECHILD) { child = nil }
      }
      if dopa_stop_requested() != 0 && !stopping {
        guard shutdown(channel, SHUT_WR) == 0 else {
          throw systemError("request session release")
        }
        stopping = true
      }
      var descriptor = pollfd(fd: channel, events: Int16(POLLIN), revents: 0)
      let count = poll(&descriptor, 1, 100)
      if count < 0 {
        if errno == EINTR { continue }
        throw systemError("poll guardian")
      }
      guard descriptor.revents & Int16(POLLNVAL) == 0 else {
        throw DopaError("invalid guardian channel")
      }
      if count == 0 { continue }
      var byte: UInt8 = 0
      let received = Darwin.read(channel, &byte, 1)
      if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      if received == 0 || (received < 0 && errno == ECONNRESET) {
        if stopping {
          throw DopaError("guardian disconnected before confirming cleanup; recovery may be needed")
        }
        return false
      }
      guard received > 0 else { throw systemError("read guardian response") }
      switch byte {
      case Wire.ready where !ready:
        ready = true
        everReady = true
        let pid = try LocalSocket.peerPID(channel)
        log("sleep disabled; Ctrl+C to release this session (pid \(getpid()), guardian \(pid))")
      case Wire.done:
        return true
      case Wire.failed:
        throw DopaError(
          "guardian could not complete this session; check its error output and recovery journal")
      default:
        throw DopaError("invalid guardian response")
      }
    }
  }

  private static func spawn(executable: URL, environment: [String: String]) throws -> pid_t {
    let argv = [strdup(executable.path), nil]
    let envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
      + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    guard argv[0] != nil, envp.dropLast().allSatisfy({ $0 != nil }) else {
      throw DopaError("cannot allocate guardian arguments")
    }
    var child: pid_t = 0
    let status = argv.withUnsafeBufferPointer { args in
      envp.withUnsafeBufferPointer { env in
        dopa_spawn_guardian(&child, executable.path, args.baseAddress, env.baseAddress)
      }
    }
    guard status == 0 else {
      throw DopaError("start guardian: \(String(cString: strerror(status)))")
    }
    return child
  }

  public static func guardian(
    path: String = "/var/db/dopa", power: any Power, controls: any Controls
  ) throws {
    guard setsid() >= 0 else { throw systemError("detach guardian session") }
    let state: State
    do { state = try State(path: path) } catch is State.InUse {
      // Another candidate won. Frontends retry its socket; never unlink it.
      return
    }
    defer { withExtendedLifetime(state) {} }
    try Session.recover(power: power, state: state)
    let listener = try LocalSocket.listen(state: state)
    defer {
      // Still holding the election lock, including throughout restoration.
      do { try LocalSocket.remove(state: state) } catch { log("remove socket: \(error)") }
      withExtendedLifetime(listener) {}
    }
    let coordinator = Coordinator(
      listener: listener.value, state: state, power: power, controls: controls)
    try coordinator.run()
  }
}

// One-byte versioned registration (0xA0..0xA3) and replies. No persisted client
// count: the open socket connections are the live session ownership records.
enum Wire {
  static let ready: UInt8 = 82
  static let done: UInt8 = 68
  static let failed: UInt8 = 70

  static func send(_ value: UInt8, to descriptor: Int32) -> Bool {
    var value = value
    while Darwin.write(descriptor, &value, 1) != 1 {
      if errno == EINTR { continue }
      return false
    }
    return true
  }
}
