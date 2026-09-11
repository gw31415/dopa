import CDopa
import Darwin

enum LocalSocket {
  private static let name = "control.sock"

  static func connect(path: String) throws -> Descriptor? {
    let socketPath = socketPath(for: path)
    guard try validateSocketEntry(at: socketPath) else { return nil }

    let fd = dopa_unix_socket()
    guard fd >= 0 else {
      let failure = errno
      if isTransient(failure) { return nil }
      throw systemError("create control socket")
    }
    let socket = Descriptor(fd)
    if dopa_unix_connect(fd, socketPath) != 0 {
      let failure = errno
      if isTransient(failure) { return nil }
      throw systemError("connect control socket")
    }
    try validatePeer(fd)
    return socket
  }

  static func listen(state: State) throws -> Descriptor {
    let fd = dopa_unix_socket()
    guard fd >= 0 else { throw systemError("create control listener") }
    let listener = Descriptor(fd)
    let socketPath = socketPath(for: state.path)

    try removeExistingSocket(state)
    guard dopa_unix_bind(fd, socketPath) == 0 else {
      throw systemError("bind control socket")
    }
    do {
      guard dopa_unix_listen(fd, 16) == 0 else {
        throw systemError("listen on control socket")
      }
    } catch {
      try? remove(state: state)
      throw error
    }
    return listener
  }

  static func remove(state: State) throws {
    try removeExistingSocket(state)
    // removeExistingSocket performs the unlink and directory validation. A
    // separate fsync makes the pathname removal durable before state cleanup.
    guard fsync(state.directoryFD) == 0 else {
      throw systemError("sync control socket removal")
    }
  }

  static func accept(listener: Int32) throws -> Descriptor? {
    let fd = dopa_unix_accept(listener)
    guard fd >= 0 else {
      if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
      throw systemError("accept control socket")
    }
    let socket = Descriptor(fd)
    try validatePeer(fd)
    return socket
  }

  static func peerPID(_ descriptor: Int32) throws -> pid_t {
    var pid: pid_t = 0
    guard dopa_unix_peer_pid(descriptor, &pid) == 0 else {
      throw systemError("read control peer pid")
    }
    return pid
  }

  private static func socketPath(for path: String) -> String {
    path.hasSuffix("/") ? path + name : path + "/" + name
  }

  private static func isTransient(_ error: Int32) -> Bool {
    error == ENOENT || error == ECONNREFUSED || error == EAGAIN || error == EINPROGRESS
  }

  private static func validateSocketEntry(at path: String) throws -> Bool {
    var info = stat()
    if lstat(path, &info) != 0 {
      if errno == ENOENT { return false }
      throw systemError("inspect control socket")
    }
    guard info.st_mode & S_IFMT == S_IFSOCK else {
      throw DopaError("unsafe control socket: expected a socket")
    }
    guard info.st_uid == geteuid() else {
      throw DopaError("unsafe control socket: owner mismatch")
    }
    return true
  }

  private static func removeExistingSocket(_ state: State) throws {
    var info = stat()
    if fstatat(state.directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return }
      throw systemError("inspect control socket")
    }
    guard info.st_mode & S_IFMT == S_IFSOCK else {
      throw DopaError("unsafe control socket: expected a socket")
    }
    guard info.st_uid == geteuid() else {
      throw DopaError("unsafe control socket: owner mismatch")
    }
    guard unlinkat(state.directoryFD, name, 0) == 0 else {
      throw systemError("remove control socket")
    }
  }

  private static func validatePeer(_ descriptor: Int32) throws {
    var uid: uid_t = 0
    guard dopa_unix_peer_uid(descriptor, &uid) == 0 else {
      throw systemError("read control peer uid")
    }
    guard uid == geteuid() else {
      throw DopaError("control socket peer owner mismatch")
    }
  }
}
