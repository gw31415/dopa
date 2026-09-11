import Darwin
import DopaCore
import Foundation

func run() throws {
  let options: Options
  switch try Options.parse(Array(CommandLine.arguments.dropFirst())) {
  case .help:
    print(Options.help)
    return
  case .run(let parsed): options = parsed
  }
  guard geteuid() == 0 else { throw DopaError("root is required; run sudo dopa") }
  try Runtime.installSignals()
  if ProcessInfo.processInfo.environment["DOPA_INTERNAL_GUARDIAN"] == "1" {
    try Runtime.guardian(
      channel: Runtime.inheritedChannel(), power: NativePower(), controls: NativeControls(),
      options: options)
  } else {
    guard let executable = Bundle.main.executableURL else {
      throw DopaError("cannot locate executable")
    }
    try Runtime.frontend(
      executable: executable, arguments: options.arguments,
      environment: ["DOPA_INTERNAL_GUARDIAN": "1"])
  }
}

do { try run() } catch {
  log(String(describing: error))
  exit(1)
}
