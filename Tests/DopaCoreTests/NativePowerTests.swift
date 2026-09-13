import IOKit
import XCTest

@testable import DopaCore

final class NativePowerTests: XCTestCase {
  private enum ProbeError: Error, Equatable {
    case failed
  }

  func testNativeControlsSurfacesFirstReadFailureAndUsesFreshServiceNextCall() throws {
    let stale: io_service_t = 101
    let fresh: io_service_t = 202
    var fetched: [io_service_t] = []
    var read: [io_service_t] = []
    var released: [io_service_t] = []
    var services = [stale, fresh]
    var controls: NativeControls? = NativeControls(
      fetchLidService: {
        let service = services.removeFirst()
        fetched.append(service)
        return service
      },
      readLidState: { service in
        read.append(service)
        if service == stale { throw ProbeError.failed }
        return true
      },
      releaseLidService: { released.append($0) })

    XCTAssertThrowsError(try controls?.lidClosed()) { error in
      XCTAssertEqual(error as? ProbeError, .failed)
    }
    // The failed call releases the stale handle and may fetch the replacement,
    // but it must not re-read and hide the original error.
    XCTAssertEqual(fetched, [stale, fresh])
    XCTAssertEqual(read, [stale])
    XCTAssertEqual(released, [stale])

    XCTAssertEqual(try controls?.lidClosed(), true)
    XCTAssertEqual(fetched, [stale, fresh])
    XCTAssertEqual(read, [stale, fresh])
    XCTAssertEqual(released, [stale])

    XCTAssertEqual(try controls?.lidClosed(), true)
    XCTAssertEqual(fetched, [stale, fresh])
    XCTAssertEqual(read, [stale, fresh, fresh])
    XCTAssertEqual(released, [stale])

    controls = nil
    XCTAssertEqual(released, [stale, fresh])
  }
}
