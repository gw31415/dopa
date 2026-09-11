import CDopa
import Darwin
import Foundation

func systemError(_ action: String) -> DopaError {
  DopaError("\(action): \(String(cString: strerror(errno)))")
}

final class Descriptor {
  let value: Int32
  init(_ value: Int32) { self.value = value }
  deinit { Darwin.close(value) }
}

// A stable directory and journal format provide exclusive session ownership
// and recovery across launches.
public final class State {
  public let path: String
  private let directory: Descriptor
  private let lock: Descriptor
  private static let record = Data("dopa-v1\noriginal=0\n".utf8)

  public init(path: String = "/var/db/dopa") throws {
    self.path = path
    if mkdir(path, 0o700) == 0 {
      let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
      let fd = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0 else { throw systemError("open state parent") }
      let parentFD = Descriptor(fd)
      guard fsync(parentFD.value) == 0 else { throw systemError("sync state parent") }
    } else if errno != EEXIST {
      throw systemError("create state directory")
    }

    let dir = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard dir >= 0 else { throw systemError("open state directory") }
    let directory = Descriptor(dir)
    var info = stat()
    guard fstat(dir, &info) == 0 else { throw systemError("inspect state directory") }
    guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
      throw DopaError("state directory must be owned by the current user with mode 0700")
    }
    let lock = try Self.open(directory: dir, name: "lock", create: true)
    guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else {
      throw DopaError("another dopa session is running (or lock is unavailable)")
    }
    self.directory = directory
    self.lock = lock
  }

  private static func open(directory: Int32, name: String, create: Bool) throws -> Descriptor {
    let fd = dopa_openat(
      directory, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
    guard fd >= 0 else { throw systemError("open state file \(name)") }
    let file = Descriptor(fd)
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw systemError("inspect state file") }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else {
      throw DopaError("unsafe state file: \(name)")
    }
    return file
  }

  public func pending() throws -> Bool {
    // Probe without following links; distinguish ENOENT from malformed or
    // inaccessible entries before the validated open.
    var info = stat()
    if fstatat(directory.value, "session", &info, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return false }
      throw systemError("inspect recovery journal")
    }
    let file = try Self.open(directory: directory.value, name: "session", create: false)
    var bytes = [UInt8](repeating: 0, count: 128)
    var count = 0
    while count < bytes.count {
      let amount = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(file.value, buffer.baseAddress!.advanced(by: count), buffer.count - count)
      }
      if amount < 0 {
        if errno == EINTR { continue }
        throw systemError("read recovery journal")
      }
      if amount == 0 { break }
      count += amount
    }
    guard Data(bytes.prefix(count)) == Self.record else {
      throw DopaError("invalid recovery journal; refusing to change power settings")
    }
    return true
  }

  public func save() throws {
    guard try !pending() else { throw DopaError("recovery must finish before starting") }
    let file = try Self.open(directory: directory.value, name: "session.new", create: true)
    guard ftruncate(file.value, 0) == 0 else { throw systemError("truncate temporary journal") }
    try Self.record.withUnsafeBytes { buffer in
      var written = 0
      while written < buffer.count {
        let amount = Darwin.write(
          file.value, buffer.baseAddress!.advanced(by: written), buffer.count - written)
        if amount < 0 {
          if errno == EINTR { continue }
          throw systemError("write recovery journal")
        }
        guard amount > 0 else { throw DopaError("zero-length journal write") }
        written += amount
      }
    }
    guard fsync(file.value) == 0, dopa_full_sync(file.value) == 0 else {
      throw systemError("flush recovery journal")
    }
    guard renameat(directory.value, "session.new", directory.value, "session") == 0 else {
      throw systemError("publish recovery journal")
    }
    try sync()
  }

  public func clear() throws {
    guard unlinkat(directory.value, "session", 0) == 0 else {
      throw systemError("remove recovery journal")
    }
    try sync()
  }
  private func sync() throws {
    guard fsync(directory.value) == 0 else { throw systemError("sync state directory") }
  }
}
