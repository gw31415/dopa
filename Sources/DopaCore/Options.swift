import Foundation

public struct DopaError: Error, CustomStringConvertible {
  public let description: String
  public init(_ message: String) { description = message }
}

public struct Options: Equatable, Sendable {
  public var keepDisplayOn: Bool
  public var stopOnLidClose: Bool
  public init(keepDisplayOn: Bool = false, stopOnLidClose: Bool = false) {
    self.keepDisplayOn = keepDisplayOn
    self.stopOnLidClose = stopOnLidClose
  }
  public var arguments: [String] {
    (keepDisplayOn ? ["--keep-display-on"] : []) + (stopOnLidClose ? ["--stop-on-lid-close"] : [])
  }
  public enum Action: Equatable {
    case run(Options)
    case help
  }
  public static func parse(_ args: [String]) throws -> Action {
    var options = Options()
    var help = false
    var endedOptions = false
    for arg in args {
      if endedOptions {
        throw DopaError("unknown argument: \(arg); use dopa --help")
      }
      switch arg {
      case "--":
        endedOptions = true
      case "--keep-display-on":
        options.keepDisplayOn = true
      case "--stop-on-lid-close":
        options.stopOnLidClose = true
      case "--help":
        help = true
      case let shortGroup where shortGroup.hasPrefix("-") && !shortGroup.hasPrefix("--"):
        let flags = shortGroup.utf8.dropFirst()
        guard !flags.isEmpty else {
          throw DopaError("unknown argument: \(arg); use dopa --help")
        }
        for flag in flags {
          switch flag {
          case UInt8(ascii: "d"): options.keepDisplayOn = true
          case UInt8(ascii: "l"): options.stopOnLidClose = true
          case UInt8(ascii: "h"): help = true
          default:
            throw DopaError("unknown argument: \(arg); use dopa --help")
          }
        }
      default:
        throw DopaError("unknown argument: \(arg); use dopa --help")
      }
    }
    return help ? .help : .run(options)
  }
  public static let help = """
    dopa — keep your Mac awake

    Usage: sudo dopa [OPTIONS]

      -d, --keep-display-on     Prevent idle display sleep (default: off)
      -l, --stop-on-lid-close   End this session when the lid closes
                               (default: off; also exits if already closed)
      -h, --help                Print help; no sudo required

    Without options, keep the system awake even with the lid closed.
    Multiple instances share one guardian. Ctrl+C ends this session.
    The original sleep setting is restored after the last session ends.
    No battery-level cutoff is applied.
    """
}

public func log(_ message: String) {
  // A closed terminal must not interrupt restoration.
  try? FileHandle.standardError.write(contentsOf: Data("dopa: \(message)\n".utf8))
}
