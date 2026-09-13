import Dispatch
import Foundation

/// Watches managed files and their parent directories with vnode dispatch
/// sources and invokes `onChange` on file writes, attribute changes,
/// renames, deletes, and revocations, plus on a bounded fallback tick.
///
/// The watcher never decides installed state itself: every notification only
/// means "re-verify with the secure stat checks". That keeps TOCTOU and
/// symlink-replacement behavior identical to polling, because the
/// lstat-based verification in `DaemonInstaller.isInstalled` stays the sole
/// authority (and the elevated commands re-verify independently).
///
/// Rotation is handled by re-opening: a revoked or replaced file is watched
/// again once it reappears (directory events report creations), and the
/// fallback tick repairs anything the event stream missed.
///
/// Thread safety: all mutable state is confined to the private serial queue
/// (external calls hop onto it synchronously), hence the unchecked Sendable.
final class ManagedFileWatcher: @unchecked Sendable {
  /// Matches the previous polling bound when a vnode notification is missed.
  static let defaultFallbackInterval: TimeInterval = 0.5

  private let files: [URL]
  private let fallbackInterval: TimeInterval
  private let onTearDown: @Sendable () -> Void
  /// The callback must invoke its completion after the authoritative refresh
  /// finishes. Keeping one delivery in flight provides backpressure when the
  /// main actor is busy instead of creating an unbounded queue of refresh
  /// tasks from a continuous vnode event stream.
  private let onChange: @Sendable (@escaping @Sendable () -> Void) -> Void
  private let queue = DispatchQueue(label: "dev.amas.dopa.ui.installwatch")
  private let queueKey = DispatchSpecificKey<UInt8>()

  // Queue-confined state. start()/stop() hop onto the queue synchronously.
  private var started = false
  private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
  private var dirSources: [String: DispatchSourceFileSystemObject] = [:]
  private var fallbackTimer: DispatchSourceTimer?
  private var notificationPending = false
  private var notificationDeliveryStarted = false
  private var notificationDirty = false
  private var notificationGeneration: UInt64 = 0

  init(
    files: [URL], fallbackInterval: TimeInterval = ManagedFileWatcher.defaultFallbackInterval,
    onTearDown: @Sendable @escaping () -> Void = {},
    onChange: @Sendable @escaping (@escaping @Sendable () -> Void) -> Void
  ) {
    self.files = files
    self.fallbackInterval = fallbackInterval
    self.onTearDown = onTearDown
    self.onChange = onChange
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    syncOnQueue { tearDown() }
  }

  func start() {
    syncOnQueue {
      guard !started else { return }
      started = true
      repair()
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + fallbackInterval, repeating: fallbackInterval)
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        self.repair()
        // The fallback itself is already rate-limited. Fire it directly so
        // the worst-case reflection time never exceeds fallbackInterval.
        self.scheduleNotification(delay: .now())
      }
      timer.resume()
      fallbackTimer = timer
    }
  }

  func stop() {
    syncOnQueue { tearDown() }
  }

  // MARK: - Queue-confined internals

  private func tearDown() {
    let wasActive = started || fallbackTimer != nil || !fileSources.isEmpty || !dirSources.isEmpty
    started = false
    notificationGeneration &+= 1
    notificationPending = false
    notificationDeliveryStarted = false
    notificationDirty = false
    fallbackTimer?.cancel()
    fallbackTimer = nil
    for source in fileSources.values { source.cancel() }
    for source in dirSources.values { source.cancel() }
    fileSources.removeAll()
    dirSources.removeAll()
    if wasActive { onTearDown() }
  }

  private func syncOnQueue(_ operation: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil { operation() }
    else { queue.sync(execute: operation) }
  }

  /// File and directory sources commonly report the same atomic replacement.
  /// Coalesce that burst before hopping to MainActor while staying well inside
  /// the 0.5-second compatibility bound.
  private func scheduleNotification() {
    scheduleNotification(delay: .now() + .milliseconds(20))
  }

  private func scheduleNotification(delay: DispatchTime) {
    guard started else { return }
    if notificationPending {
      // Events received during the debounce window are already represented by
      // the pending refresh. An event received while that refresh is actually
      // running needs one follow-up so a change racing the stat calls is not
      // lost until the fallback tick.
      if notificationDeliveryStarted { notificationDirty = true }
      return
    }
    notificationPending = true
    notificationDeliveryStarted = false
    let generation = notificationGeneration
    queue.asyncAfter(deadline: delay) { [weak self] in
      guard let self, self.started, self.notificationGeneration == generation else { return }
      self.notificationDeliveryStarted = true
      self.onChange { [weak self] in
        self?.queue.async { [weak self] in
          guard let self, self.started, self.notificationGeneration == generation,
            self.notificationPending
          else { return }
          self.notificationPending = false
          self.notificationDeliveryStarted = false
          if self.notificationDirty {
            self.notificationDirty = false
            self.scheduleNotification()
          }
        }
      }
    }
  }

  private func repair() {
    var directories = Set<String>()
    for file in files {
      directories.insert(file.deletingLastPathComponent().path)
      ensureFileWatch(path: file.path)
    }
    for directory in directories { ensureDirWatch(path: directory) }
  }

  private func ensureFileWatch(path: String) {
    if fileSources[path] != nil { return }
    let fd = path.withCString { open($0, O_EVTONLY | O_CLOEXEC) }
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.delete, .write, .extend, .attrib, .rename, .revoke],
      queue: queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      // The watched inode is gone or replaced: drop the source (its cancel
      // handler closes the fd) so the next repair watches the new inode.
      if !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
        source.cancel()
        self.fileSources.removeValue(forKey: path)
      }
      self.repair()
      self.scheduleNotification()
    }
    source.setCancelHandler { close(fd) }
    fileSources[path] = source
    source.resume()
  }

  private func ensureDirWatch(path: String) {
    if dirSources[path] != nil { return }
    let fd = path.withCString { open($0, O_EVTONLY | O_CLOEXEC) }
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      if !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
        source.cancel()
        self.dirSources.removeValue(forKey: path)
      }
      self.repair()
      self.scheduleNotification()
    }
    source.setCancelHandler { close(fd) }
    dirSources[path] = source
    source.resume()
  }
}
