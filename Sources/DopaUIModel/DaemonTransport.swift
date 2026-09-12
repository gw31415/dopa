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
public final class SocketTransport: DaemonTransport, @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.dopa.ui.socket", qos: .userInitiated)
  private let path: String
  private let requireRoot: Bool
  // Access only inside `queue`.
  private var connection: DopaConnection?

  public init(path: String = DopaConnection.defaultSocketPath, requireRoot: Bool = true) {
    self.path = path
    self.requireRoot = requireRoot
  }

  private func perform<T: Sendable>(
    _ operation: @escaping @Sendable (SocketTransport) throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do { continuation.resume(returning: try operation(self)) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  public func connect() async throws -> DaemonHandshake {
    try await perform { owner in
      owner.connection?.close()
      owner.connection = nil
      let connection = try DopaConnection(path: owner.path, requireRoot: owner.requireRoot, clientName: "Dopa UI")
      do {
        let snapshot = try DaemonSnapshot(connection.request(method: "status.subscribe"))
        owner.connection = connection
        return DaemonHandshake(capabilities: connection.capabilities, snapshot: snapshot)
      } catch { connection.close(); throw error }
    }
  }

  public func request(method: String, params: JSONValue) async throws -> JSONValue {
    try await perform { owner in
      guard let connection = owner.connection else { throw DopaClientError.connectionClosed }
      return try connection.request(method: method, params: params)
    }
  }

  public func poll() async throws -> [JSONValue] {
    try await perform { owner in
      guard let connection = owner.connection else { throw DopaClientError.connectionClosed }
      var events: [JSONValue] = []
      // Bounded draining keeps commands responsive even under frequent snapshots.
      for _ in 0..<64 {
        guard let event = try connection.receive(timeout: 0.001) else { break }
        events.append(event)
      }
      return events
    }
  }

  public func close() async {
    _ = try? await perform { owner in owner.connection?.close(); owner.connection = nil }
  }
}
