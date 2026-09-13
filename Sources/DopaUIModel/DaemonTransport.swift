import DopaClient
import DopaProtocol
import Foundation

public struct DaemonHandshake: Sendable {
  public let capabilities: Set<String>
  public let snapshot: DaemonSnapshot
  public init(capabilities: Set<String>, snapshot: DaemonSnapshot) {
    self.capabilities = capabilities
    self.snapshot = snapshot
  }
}

public protocol DaemonTransport: Sendable {
  func connect() async throws -> DaemonHandshake
  func request(method: String, params: JSONValue) async throws -> JSONValue
  func poll() async throws -> [JSONValue]
  func close() async
}

/// Owns the synchronous socket exclusively on one dedicated serial queue.
/// No socket wait, connection, or request runs on the main actor.
///
/// Request/poll exclusion is preserved by the serial queue: at most one
/// connection operation runs at a time, so a poll can never swallow the
/// response to an in-flight request. `close()` does not use the queue: it
/// invalidates the current connection generation, detaches the connection,
/// and wakes its receive directly. A connection whose handshake finishes
/// after close can therefore never publish itself back into the transport.
public final class SocketTransport: DaemonTransport, @unchecked Sendable {
  /// Upper bound for one blocking poll. Events, interrupts, and disconnects
  /// return earlier; the bound only caps unknown stalls.
  private static let pollBudget: TimeInterval = 30
  /// Burst drain after the first event of a poll.
  private static let drainTimeout: TimeInterval = 0.005
  /// Maximum events per poll, matching the previous drain bound.
  private static let drainLimit = 64

  private let queue = DispatchQueue(label: "dev.amas.dopa.ui.socket", qos: .userInitiated)
  private let path: String
  private let requireRoot: Bool
  private let lock = NSLock()
  // Guarded by `lock`. Every connect and close advances `generation` so a
  // candidate built while close is running cannot become current afterwards.
  private var connection: DopaConnection?
  private var generation: UInt64 = 0

  public init(path: String = DopaConnection.defaultSocketPath, requireRoot: Bool = true) {
    self.path = path
    self.requireRoot = requireRoot
  }

  private func takeConnection() -> DopaConnection? {
    lock.lock()
    defer { lock.unlock() }
    return connection
  }

  private func beginConnect() -> (generation: UInt64, previous: DopaConnection?) {
    lock.lock()
    generation &+= 1
    let token = generation
    let previous = connection
    connection = nil
    lock.unlock()
    return (token, previous)
  }

  private func generationIsCurrent(_ token: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == token
  }

  private func installConnection(_ next: DopaConnection, generation token: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard generation == token, connection == nil else { return false }
    connection = next
    return true
  }

  private func perform<T: Sendable>(
    _ operation: @escaping @Sendable (DopaConnection) throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          guard let connection = takeConnection() else {
            throw DopaClientError.connectionClosed
          }
          continuation.resume(returning: try operation(connection))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  public func connect() async throws -> DaemonHandshake {
    // Invalidate first, then preempt any blocked poll without waiting for the
    // queue. The token prevents close or a newer connect from being undone by
    // this handshake when it eventually completes.
    let attempt = beginConnect()
    let generation = attempt.generation
    attempt.previous?.close()
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          let connection = try DopaConnection(
            path: path, requireRoot: requireRoot, clientName: "Dopa UI")
          do {
            guard generationIsCurrent(generation) else {
              throw DopaClientError.connectionClosed
            }
            let snapshot = try DaemonSnapshot(connection.request(method: "status.subscribe"))
            guard installConnection(connection, generation: generation) else {
              throw DopaClientError.connectionClosed
            }
            continuation.resume(
              returning: DaemonHandshake(
                capabilities: connection.capabilities, snapshot: snapshot))
          } catch { connection.close(); throw error }
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  public func request(method: String, params: JSONValue) async throws -> JSONValue {
    // Wake a blocked poll first so the request does not wait out its budget.
    // The poll aborts promptly, this request runs next on the serial queue,
    // and request/response exclusion is unchanged.
    takeConnection()?.interruptReceive()
    return try await perform { connection in
      try connection.request(method: method, params: params)
    }
  }

  public func poll() async throws -> [JSONValue] {
    try await perform { connection in
      var events: [JSONValue] = []
      // Block for the first event so delivery is push-driven instead of
      // cadence-driven; interrupts (new requests, close) and disconnects
      // return earlier. Afterwards drain the burst that already arrived.
      if let first = try connection.receive(timeout: Self.pollBudget, interruptible: true) {
        events.append(first)
        while events.count < Self.drainLimit,
          let next = try connection.receive(timeout: Self.drainTimeout)
        {
          events.append(next)
        }
      }
      return events
    }
  }

  public func close() async {
    closeSync()
  }

  private func closeSync() {
    lock.lock()
    generation &+= 1
    let connection = self.connection
    self.connection = nil
    lock.unlock()
    connection?.close()
  }
}
