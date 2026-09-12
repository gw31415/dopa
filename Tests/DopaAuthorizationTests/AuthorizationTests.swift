import DopaAuthorization
import Foundation
import Security
import XCTest

final class AuthorizationTests: XCTestCase {
  func testExternalFormRequiresExactCanonicalBase64() {
    let data = Data(repeating: 0xAB, count: MemoryLayout<Security.AuthorizationExternalForm>.size)
    let encoded = data.base64EncodedString()
    XCTAssertEqual(DopaAuthorization.decodeExternalForm(encoded), data)
    for invalid in ["", "not base64", encoded + "\n", String(encoded.dropLast()),
      Data(repeating: 0, count: data.count - 1).base64EncodedString(),
      Data(repeating: 0, count: data.count + 1).base64EncodedString()]
    {
      XCTAssertNil(DopaAuthorization.decodeExternalForm(invalid))
    }
  }

  func testInvalidExternalFormNeverAuthorizes() {
    XCTAssertFalse(DopaAuthorization.verifyExternalForm(Data()))
    XCTAssertFalse(DopaAuthorization.verifyExternalForm(Data(repeating: 0, count: 32)))
  }

  func testExternalizingAnUnprivilegedReferenceDoesNotGrantAdminRights() throws {
    var reference: AuthorizationRef?
    XCTAssertEqual(AuthorizationCreate(nil, nil, [], &reference), errAuthorizationSuccess)
    let created = try XCTUnwrap(reference)
    defer { AuthorizationFree(created, [.destroyRights]) }
    var form = Security.AuthorizationExternalForm()
    XCTAssertEqual(AuthorizationMakeExternalForm(created, &form), errAuthorizationSuccess)
    let data = withUnsafeBytes(of: &form) { Data($0) }
    // No interaction/extend flags are used: this test cannot display UI or
    // grant rights, even when it runs in an administrator's login session.
    XCTAssertFalse(DopaAuthorization.verifyExternalForm(data))
  }
}
