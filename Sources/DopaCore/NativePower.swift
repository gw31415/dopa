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
  public init() {}
  public func keepDisplayOn() throws {
    if displayAssertion != nil { return }
    var assertion: IOPMAssertionID = 0
    let status = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), "dopa" as CFString, &assertion)
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
  }
  public func lidClosed() throws -> Bool {
    guard let matching = IOServiceMatching("IOPMrootDomain") else {
      throw DopaError("cannot create IOKit matching dictionary")
    }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else {
      throw DopaError("cannot find power-management root domain")
    }
    defer { IOObjectRelease(service) }
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
