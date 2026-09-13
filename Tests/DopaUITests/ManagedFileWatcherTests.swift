import Foundation
@testable import DopaUI
import XCTest

/// The installation watcher must report writes, attribute changes,
/// deletes, recreations, and atomic replacements promptly, and its fallback
/// tick must fire without any filesystem activity.
final class ManagedFileWatcherTests: XCTestCase {
  private func makeFiles() throws -> (dir: URL, files: [URL]) {
    let dir = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("dopa-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    let files = (0..<2).map { dir.appendingPathComponent("managed-\($0)") }
    for file in files { try Data("v1".utf8).write(to: file) }
    return (dir, files)
  }

  private func awaitFire(
    _ fires: LockedCounter, _ label: String, timeout: TimeInterval = 5,
    _ operation: () throws -> Void
  ) throws {
    // Snapshot BEFORE the operation: an event may be delivered within
    // microseconds of the syscall returning, and snapshotting after would
    // consume our own op's notification and stall until the fallback tick.
    // One filesystem operation may notify more than once (file and directory
    // sources can both fire), so only wait for the count to grow at all.
    let seen = fires.value
    try operation()
    let deadline = Date().addingTimeInterval(timeout)
    while fires.value == seen, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertGreaterThan(fires.value, seen, "watcher did not report \(label)")
  }

  func testWriteAttributeDeleteRecreateAndReplace() throws {
    let (dir, files) = try makeFiles()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fires = LockedCounter()
    let watcher = ManagedFileWatcher(files: files) { completed in
      fires.increment()
      completed()
    }
    watcher.start()
    defer { watcher.stop() }

    try awaitFire(fires, "write") { try Data("v2".utf8).write(to: files[0]) }

    try awaitFire(fires, "chmod") {
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files[1].path)
    }

    try awaitFire(fires, "delete") { try FileManager.default.removeItem(at: files[0]) }

    try awaitFire(fires, "recreate") { try Data("v3".utf8).write(to: files[0]) }

    try awaitFire(fires, "replace") {
      let replacement = dir.appendingPathComponent("replacement")
      try Data("v4".utf8).write(to: replacement)
      _ = try FileManager.default.replaceItemAt(files[1], withItemAt: replacement)
    }
  }

  func testFallbackTickFiresWithoutFilesystemActivity() throws {
    let (dir, files) = try makeFiles()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fires = LockedCounter()
    let watcher = ManagedFileWatcher(files: files, fallbackInterval: 0.2) { completed in
      fires.increment()
      completed()
    }
    watcher.start()
    defer { watcher.stop() }
    try awaitFire(fires, "fallback") {}
  }

  func testDefaultFallbackKeepsPreviousHalfSecondBound() throws {
    XCTAssertEqual(ManagedFileWatcher.defaultFallbackInterval, 0.5)
    let (dir, files) = try makeFiles()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fires = LockedCounter()
    let watcher = ManagedFileWatcher(files: files) { completed in
      fires.increment()
      completed()
    }
    watcher.start()
    defer { watcher.stop() }

    let start = Date()
    try awaitFire(fires, "default fallback", timeout: 1) {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
  }

  func testLastReferenceCanBeReleasedFromWatcherQueue() throws {
    let (dir, files) = try makeFiles()
    defer { try? FileManager.default.removeItem(at: dir) }
    let released = expectation(description: "watcher released from callback")
    let holder = LockedWatcherHolder()
    var watcher: ManagedFileWatcher? = ManagedFileWatcher(
      files: files, onTearDown: { released.fulfill() }
    ) { completed in
      holder.clear()
      completed()
    }
    holder.store(watcher!)
    watcher!.start()
    watcher = nil
    try Data("changed".utf8).write(to: files[0])
    wait(for: [released], timeout: 1)
  }

  func testContinuousEventsKeepOnlyOneRefreshInFlight() throws {
    let (dir, files) = try makeFiles()
    defer { try? FileManager.default.removeItem(at: dir) }
    let deliveries = LockedCounter()
    let completion = LockedCompletionHolder()
    let watcher = ManagedFileWatcher(files: files, fallbackInterval: 5) { completed in
      deliveries.increment()
      completion.store(completed)
    }
    watcher.start()
    defer {
      completion.take()?()
      watcher.stop()
    }

    try Data("first".utf8).write(to: files[0])
    let deadline = Date().addingTimeInterval(1)
    while deliveries.value == 0, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(deliveries.value, 1)

    for index in 0..<20 {
      try Data("change-\(index)".utf8).write(to: files[0])
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(deliveries.value, 1, "a held refresh must apply backpressure")

    completion.take()?()
    let followUpDeadline = Date().addingTimeInterval(1)
    while deliveries.value < 2, Date() < followUpDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(deliveries.value, 2, "changes during refresh need one follow-up")
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
}

private final class LockedWatcherHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var watcher: ManagedFileWatcher?

  func store(_ watcher: ManagedFileWatcher) {
    lock.lock()
    self.watcher = watcher
    lock.unlock()
  }

  func clear() {
    lock.lock()
    watcher = nil
    lock.unlock()
  }
}

private final class LockedCompletionHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: (@Sendable () -> Void)?

  func store(_ completion: @escaping @Sendable () -> Void) {
    lock.lock()
    self.completion = completion
    lock.unlock()
  }

  func take() -> (@Sendable () -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    let value = completion
    completion = nil
    return value
  }
}
