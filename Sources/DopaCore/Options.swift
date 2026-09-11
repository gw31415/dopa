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
    for arg in args {
      switch arg {
      case "-d", "--keep-display-on": options.keepDisplayOn = true
      case "-l", "--stop-on-lid-close": options.stopOnLidClose = true
      case "-h", "--help": help = true
      default: throw DopaError("unknown argument: \(arg); use dopa --help")
      }
    }
    return help ? .help : .run(options)
  }
  public static let help = """
    dopa — keep your Mac awake

    Usage: sudo dopa [OPTIONS]

      -d, --keep-display-on     Prevent idle display sleep (default: off)
      -l, --stop-on-lid-close   Restore settings and exit when the lid closes
                               (default: off; also exits if already closed)
      -h, --help                Print help; no sudo required

    Without options, keep the system awake even with the lid closed.
    Ctrl+C restores the original sleep setting and exits.
    No battery-level cutoff is applied.
    """
}

public func log(_ message: String) {
  // A closed terminal must not interrupt restoration.
  try? FileHandle.standardError.write(contentsOf: Data("dopa: \(message)\n".utf8))
}
