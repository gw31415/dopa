import CDopa
import Darwin
import Foundation

public enum Runtime {
  public static func installSignals() throws {
    guard dopa_install_signals() == 0 else { throw systemError("install signal handlers") }
  }

  // posix_spawn launches only this executable again, never pmset/caffeinate/ioreg.
  public static func frontend(executable: URL, arguments: [String], environment: [String: String])
    throws
  {
    var sockets = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
      throw systemError("create guardian socket")
    }
    let parent = Descriptor(sockets[0])
    let childHandle = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
    defer { try? childHandle.close() }
    for fd in sockets {
      guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
        throw systemError("protect guardian descriptor")
      }
    }
    // Foundation.Process puts children in a new process group, making setsid
    // fail with EPERM. Spawn without that group change; the guardian detaches
    // before acquiring a lock or changing any power setting.
    var child: pid_t = 0
    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil })
    else {
      throw DopaError("cannot allocate guardian arguments")
    }
    let spawnStatus = argv.withUnsafeBufferPointer { args in
      envp.withUnsafeBufferPointer { env in
        dopa_spawn_guardian(&child, executable.path, args.baseAddress, env.baseAddress, sockets[1])
      }
    }
    guard spawnStatus == 0 else {
      throw DopaError("start guardian: \(String(cString: strerror(spawnStatus)))")
    }
    var active = false
    var requested = false
    var failure: Error?
    do {
      // Every fallible operation after spawn shares the shutdown-and-wait path.
      try childHandle.close()
      while true {
        if dopa_stop_requested() != 0 && !requested {
          guard shutdown(parent.value, SHUT_WR) == 0 else {
            throw systemError("request guardian shutdown")
          }
          requested = true
        }
        guard try readable(parent.value) else { continue }
        var byte: UInt8 = 0
        let count = Darwin.read(parent.value, &byte, 1)
        if count == 0 { break }
        if count < 0 {
          if errno == EINTR { continue }
          throw systemError("read guardian response")
        }
        guard byte == 82, !active else { throw DopaError("invalid guardian response") }
        active = true
        log("sleep disabled; Ctrl+C to restore (pid \(getpid()), guardian \(child))")
      }
    } catch { failure = error }
    // EOF/shutdown requests cleanup even when the frontend channel fails.
    _ = shutdown(parent.value, SHUT_RDWR)
    var exitStatus: Int32 = 0
    guard dopa_wait_guardian(child, &exitStatus) == 0 else {
      throw systemError("wait for guardian")
    }
    if let failure { throw failure }
    guard exitStatus == 0 else {
      throw DopaError(
        "guardian exited with status \(exitStatus); recovery may be needed on the next sudo dopa run"
      )
    }
  }

  public static func inheritedChannel() throws -> Int32 {
    let fd = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
    guard fd >= 0 else { throw systemError("duplicate guardian channel") }
    var kind: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) == 0, kind == SOCK_STREAM else {
      Darwin.close(fd)
      throw DopaError("guardian requires an inherited stream socket")
    }
    Darwin.close(STDIN_FILENO)
    return fd
  }

  public static func guardian(
    channel: Int32, path: String = "/var/db/dopa", power: any Power,
    controls: any Controls, options: Options
  ) throws {
    let channel = Descriptor(channel)
    guard setsid() >= 0 else { throw systemError("detach guardian session") }
    let state = try State(path: path)
    var failure: Error?
    do {
      try monitor(
        channel: channel.value, state: state, power: power, controls: controls, options: options)
    } catch { failure = error }

    // Both cleanups are attempted even when one fails. The process-scoped
    // assertion has no journal; the system setting keeps its journal on failure.
    var cleanupErrors: [String] = []
    do { try controls.releaseDisplay() } catch { cleanupErrors.append("display release: \(error)") }
    do { try Session.recover(power: power, state: state) } catch {
      cleanupErrors.append("restoration: \(error); journal retained at \(path)")
    }
    if !cleanupErrors.isEmpty {
      let primary = failure.map { "\($0); " } ?? ""
      throw DopaError(primary + cleanupErrors.joined(separator: "; "))
    }
    if let failure { throw failure }
  }

  private static func monitor(
    channel: Int32, state: State, power: any Power,
    controls: any Controls, options: Options
  ) throws {
    if dopa_stop_requested() != 0 { return }
    if options.stopOnLidClose, try controls.lidClosed() {
      log("lid is closed; ending session")
      return
    }
    try Session.start(power: power, state: state)
    if options.keepDisplayOn { try controls.keepDisplayOn() }
    if dopa_stop_requested() != 0 { return }
    if options.stopOnLidClose, try controls.lidClosed() { return }
    var ready: UInt8 = 82
    while Darwin.write(channel, &ready, 1) != 1 {
      if errno == EINTR { continue }
      throw systemError("send guardian readiness")
    }
    var lastCheck = DispatchTime.now().uptimeNanoseconds
    while dopa_stop_requested() == 0 {
      if try readable(channel) {
        var byte: UInt8 = 0
        let count = Darwin.read(channel, &byte, 1)
        if count == 0 { return }
        if count < 0 && errno == EINTR { continue }
        if count < 0 { throw systemError("read frontend channel") }
        throw DopaError("unexpected frontend data")
      }
      let now = DispatchTime.now().uptimeNanoseconds
      if options.stopOnLidClose, now - lastCheck >= 250_000_000 {
        if try controls.lidClosed() {
          log("lid closed; restoring sleep settings and exiting")
          return
        }
        lastCheck = now
      }
    }
  }

  private static func readable(_ fd: Int32) throws -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let count = poll(&descriptor, 1, 100)
    if count < 0 {
      if errno == EINTR { return false }
      throw systemError("poll guardian channel")
    }
    guard descriptor.revents & Int16(POLLNVAL) == 0 else {
      throw DopaError("invalid guardian descriptor")
    }
    return count > 0
  }
}
