import CoreFoundation
import Foundation
import IOKit

public protocol LidStateReading: Sendable {
  func isClosed() throws -> Bool
}

public struct LidStateError: Error, CustomStringConvertible, Sendable {
  public let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Reads the MacBook clamshell state for an unprivileged client. Policy such
/// as whether a session should end remains with the client using this reader.
public final class NativeLidState: LidStateReading, @unchecked Sendable {
  private let lock = NSLock()
  private var rootDomain: io_service_t?
  private let fetchService: () throws -> io_service_t
  private let readState: (io_service_t) throws -> Bool
  private let releaseService: (io_service_t) -> Void

  public init() {
    fetchService = Self.fetchSystemRootDomain
    readState = Self.readSystemState
    releaseService = { service in _ = IOObjectRelease(service) }
  }

  init(
    fetchService: @escaping () throws -> io_service_t,
    readState: @escaping (io_service_t) throws -> Bool,
    releaseService: @escaping (io_service_t) -> Void
  ) {
    self.fetchService = fetchService
    self.readState = readState
    self.releaseService = releaseService
  }

  public func isClosed() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let service: io_service_t
    if let cached = rootDomain {
      service = cached
    } else {
      service = try fetchService()
      rootDomain = service
    }
    do {
      return try readState(service)
    } catch let first {
      // Surface the failed read. A fresh service is cached only for the next
      // client check, so a successful retry cannot hide this observation.
      rootDomain = nil
      releaseService(service)
      if let fresh = try? fetchService() { rootDomain = fresh }
      throw first
    }
  }

  deinit {
    if let service = rootDomain { releaseService(service) }
  }

  private static func fetchSystemRootDomain() throws -> io_service_t {
    guard let matching = IOServiceMatching("IOPMrootDomain") else {
      throw LidStateError("cannot create IOKit matching dictionary")
    }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else {
      throw LidStateError("cannot find power-management root domain")
    }
    return service
  }

  private static func readSystemState(_ service: io_service_t) throws -> Bool {
    guard
      let property = IORegistryEntryCreateCFProperty(
        service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    else {
      throw LidStateError("lid state is unavailable on this Mac")
    }
    guard CFGetTypeID(property) == CFBooleanGetTypeID() else {
      throw LidStateError("unexpected lid property type")
    }
    return CFBooleanGetValue((property as! CFBoolean))
  }
}
