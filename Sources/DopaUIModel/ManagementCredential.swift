import DopaAuthorization
import Foundation

/// A short-lived credential retained through one administrative request.
public struct ManagementCredential: Sendable {
  public let externalForm: String
  private let grant: AuthorizationGrant?

  /// For explicitly injected transports/authorization providers, including tests.
  /// The daemon independently validates every credential.
  public init(externalForm: String) { self.externalForm = externalForm; self.grant = nil }
  private init(_ grant: AuthorizationGrant) { self.grant = grant; self.externalForm = grant.externalForm }

  public static func request() async throws -> ManagementCredential {
    try await Task.detached(priority: .userInitiated) {
      ManagementCredential(try DopaAuthorization.acquireExternalForm())
    }.value
  }
}
