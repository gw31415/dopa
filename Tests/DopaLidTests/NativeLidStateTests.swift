import IOKit
import XCTest

@testable import DopaLid

final class NativeLidStateTests: XCTestCase {
  private enum ProbeError: Error, Equatable {
    case failed
  }

  func testNativeLidStateSurfacesFirstReadFailureAndUsesFreshServiceNextCall() throws {
    let stale: io_service_t = 101
    let fresh: io_service_t = 202
    var fetched: [io_service_t] = []
    var read: [io_service_t] = []
    var released: [io_service_t] = []
    var services = [stale, fresh]
    var state: NativeLidState? = NativeLidState(
      fetchService: {
        let service = services.removeFirst()
        fetched.append(service)
        return service
      },
      readState: { service in
        read.append(service)
        if service == stale { throw ProbeError.failed }
        return true
      },
      releaseService: { released.append($0) })

    XCTAssertThrowsError(try state?.isClosed()) { error in
      XCTAssertEqual(error as? ProbeError, .failed)
    }
    // The failed call releases the stale handle and may fetch the replacement,
    // but it must not re-read and hide the original error.
    XCTAssertEqual(fetched, [stale, fresh])
    XCTAssertEqual(read, [stale])
    XCTAssertEqual(released, [stale])

    XCTAssertEqual(try state?.isClosed(), true)
    XCTAssertEqual(fetched, [stale, fresh])
    XCTAssertEqual(read, [stale, fresh])
    XCTAssertEqual(released, [stale])

    XCTAssertEqual(try state?.isClosed(), true)
    XCTAssertEqual(fetched, [stale, fresh])
    XCTAssertEqual(read, [stale, fresh, fresh])
    XCTAssertEqual(released, [stale])

    state = nil
    XCTAssertEqual(released, [stale, fresh])
  }
}
