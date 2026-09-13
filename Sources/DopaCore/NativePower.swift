import CDopa
import CoreFoundation
import Foundation
import IOKit
import IOKit.pwr_mgt

public final class NativePower: Power {
  public init() {}
  public func readDisabled() throws -> Bool {
    var disabled: Int32 = 0
    let status = dopa_read_sleep_disabled(&disabled)
    guard status == 0 else { throw failure("read SleepDisabled", status) }
    return disabled != 0
  }
  public func setDisabled(_ disabled: Bool) throws {
    let status = dopa_set_sleep_disabled(disabled ? 1 : 0)
    guard status == 0 else { throw failure("set SleepDisabled", status) }
    guard try readDisabled() == disabled else {
      throw DopaError("SleepDisabled update was not confirmed")
    }
  }
  private func failure(_ action: String, _ status: Int32) -> DopaError {
    switch status {
    case -1: return DopaError("\(action): native macOS power SPI is unavailable on this OS")
    case -2:
      return DopaError(
        "\(action): SleepDisabled is missing or has an unsupported value; refusing to guess")
    default:
      return DopaError(
        "\(action) failed (IOKit status \(String(format: "0x%08x", UInt32(bitPattern: status))))")
    }
  }
}

public final class NativeControls: Controls {
  private var displayAssertion: IOPMAssertionID?
  // Cached IOPMrootDomain service so the ~0.3s lid checks (cadence owned by
  // DaemonService) skip the per-call IOKit matching lookup. A failed read is
  // surfaced as-is (fail closed); the reference is invalidated and primed
  // anew for the next call only.
  // Guarded by serviceLock; DaemonEngine calls lidClosed serially but the
  // request path may also reach it.
  private let serviceLock = NSLock()
  private var rootDomain: io_service_t?
  private let fetchLidService: () throws -> io_service_t
  private let readLidState: (io_service_t) throws -> Bool
  private let releaseLidService: (io_service_t) -> Void
  public init() {
    fetchLidService = Self.fetchSystemRootDomain
    readLidState = Self.readSystemLidClosed
    releaseLidService = { service in _ = IOObjectRelease(service) }
  }
  init(
    fetchLidService: @escaping () throws -> io_service_t,
    readLidState: @escaping (io_service_t) throws -> Bool,
    releaseLidService: @escaping (io_service_t) -> Void
  ) {
    self.fetchLidService = fetchLidService
    self.readLidState = readLidState
    self.releaseLidService = releaseLidService
  }
  public func keepDisplayOn() throws {
    if displayAssertion != nil { return }
    var assertion: IOPMAssertionID = 0
    let status = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), "Dopa" as CFString, &assertion)
    guard status == kIOReturnSuccess else {
      throw DopaError("cannot prevent display sleep (IOKit \(status))")
    }
    displayAssertion = assertion
  }
  public func releaseDisplay() throws {
    guard let assertion = displayAssertion else { return }
    let status = IOPMAssertionRelease(assertion)
    guard status == kIOReturnSuccess else {
      throw DopaError("cannot release display assertion (IOKit \(status))")
    }
    displayAssertion = nil
  }
  deinit {
    if let assertion = displayAssertion { _ = IOPMAssertionRelease(assertion) }
    if let service = rootDomain { releaseLidService(service) }
  }
  public func lidClosed() throws -> Bool {
    serviceLock.lock()
    defer { serviceLock.unlock() }
    let service: io_service_t
    if let cached = rootDomain {
      service = cached
    } else {
      service = try fetchLidService()
      rootDomain = service
    }
    do {
      return try readLidState(service)
    } catch let first {
      // Fail closed: the same call must surface the original read failure
      // (acquire/update -> lid_unavailable, active sessions -> lid_error).
      // A re-read success in this call must not hide it. Invalidate the
      // cached reference and prime a fresh one for the next call only.
      rootDomain = nil
      releaseLidService(service)
      if let fresh = try? fetchLidService() {
        rootDomain = fresh
      }
      throw first
    }
  }
  private static func fetchSystemRootDomain() throws -> io_service_t {
    guard let matching = IOServiceMatching("IOPMrootDomain") else {
      throw DopaError("cannot create IOKit matching dictionary")
    }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else {
      throw DopaError("cannot find power-management root domain")
    }
    return service
  }
  private static func readSystemLidClosed(_ service: io_service_t) throws -> Bool {
    guard
      let property = IORegistryEntryCreateCFProperty(
        service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    else {
      throw DopaError("lid state is unavailable on this Mac")
    }
    guard CFGetTypeID(property) == CFBooleanGetTypeID() else {
      throw DopaError("unexpected lid property type")
    }
    // The exact CF type check above establishes this cast's invariant.
    return CFBooleanGetValue((property as! CFBoolean))
  }
}
