import Foundation
import Security

public enum DopaAuthorizationError: Error, Equatable, Sendable, CustomStringConvertible {
  case cancelled
  case denied
  case unavailable(status: Int32)

  public var description: String {
    switch self {
    case .cancelled: return "administrator authorization was cancelled"
    case .denied: return "administrator authorization was denied"
    case .unavailable(let status): return "administrator authorization is unavailable (\(status))"
    }
  }
}

/// Keeps an authorization alive until the associated daemon request finishes.
///
/// The external form is a credential for immediate IPC only. Never persist or
/// log it. Releasing the grant revokes its rights, including exported copies.
public final class AuthorizationGrant: @unchecked Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  // This object is immutable after initialization. Authorization Services owns
  // the opaque reference; it is freed exactly once when the last owner exits.
  private let reference: AuthorizationRef
  public let externalForm: String

  fileprivate init(reference: AuthorizationRef, externalForm: String) {
    self.reference = reference
    self.externalForm = externalForm
  }

  deinit { AuthorizationFree(reference, [.destroyRights]) }

  public var description: String { "AuthorizationGrant(<redacted>)" }
  public var debugDescription: String { description }
}

public enum DopaAuthorization {
  /// An existing macOS administrator right; no custom authorization database
  /// rules or privileged executable are installed by this module.
  public static let rightName = "system.privilege.admin"

  /// Requests the system authentication UI immediately before an admin action.
  ///
  /// This call can block while the user authenticates. Keep it off the main
  /// thread and retain the returned grant until the daemon request completes.
  public static func acquireExternalForm() throws -> AuthorizationGrant {
    var reference: AuthorizationRef?
    try check(AuthorizationCreate(nil, nil, [], &reference))
    guard let reference else {
      throw DopaAuthorizationError.unavailable(status: errAuthorizationInvalidRef)
    }
    var transferred = false
    defer { if !transferred { AuthorizationFree(reference, [.destroyRights]) } }

    // Authorize fully, rather than merely preauthorizing: verification in the
    // daemon must never need to present an authentication prompt.
    try check(copyRight(reference, flags: [.interactionAllowed, .extendRights]))
    var form = Security.AuthorizationExternalForm()
    try check(AuthorizationMakeExternalForm(reference, &form))
    let data = withUnsafeBytes(of: &form) { Data($0) }
    let grant = AuthorizationGrant(reference: reference, externalForm: data.base64EncodedString())
    transferred = true
    return grant
  }

  /// Decodes only the exact canonical wire representation of an external form.
  public static func decodeExternalForm(_ encoded: String) -> Data? {
    let length = MemoryLayout<Security.AuthorizationExternalForm>.size
    guard encoded.utf8.count == ((length + 2) / 3) * 4,
      let data = Data(base64Encoded: encoded), data.count == length,
      data.base64EncodedString() == encoded
    else { return nil }
    return data
  }

  /// Checks already granted rights without extending them or interacting.
  /// Invalid, expired, missing-right, and revoked credentials all return false.
  public static func verifyExternalForm(_ data: Data) -> Bool {
    guard data.count == MemoryLayout<Security.AuthorizationExternalForm>.size else { return false }
    var form = Security.AuthorizationExternalForm()
    _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
    var reference: AuthorizationRef?
    guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
      let reference
    else { return false }
    // Free only this imported reference. The caller owns the grant's lifetime.
    defer { AuthorizationFree(reference, []) }
    return copyRight(reference, flags: []) == errAuthorizationSuccess
  }

  private static func copyRight(_ reference: AuthorizationRef, flags: AuthorizationFlags) -> OSStatus {
    rightName.withCString { name in
      var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
      return withUnsafeMutablePointer(to: &item) { pointer in
        var rights = AuthorizationRights(count: 1, items: pointer)
        return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
      }
    }
  }

  private static func check(_ status: OSStatus) throws {
    switch status {
    case errAuthorizationSuccess: return
    case errAuthorizationCanceled: throw DopaAuthorizationError.cancelled
    case errAuthorizationDenied, errAuthorizationInteractionNotAllowed:
      throw DopaAuthorizationError.denied
    default: throw DopaAuthorizationError.unavailable(status: status)
    }
  }
}
