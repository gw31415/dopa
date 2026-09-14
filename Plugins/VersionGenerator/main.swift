import Foundation

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("VersionGenerator: \(message)\n".utf8))
  exit(1)
}

guard CommandLine.arguments.count == 3 else {
  fail("expected input plist and output Swift path")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let data: Data
do {
  data = try Data(contentsOf: input)
} catch {
  fail("cannot read \(input.path): \(error)")
}

let plist: [String: Any]
do {
  guard
    let decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
      as? [String: Any]
  else {
    fail("\(input.path) is not a dictionary plist")
  }
  plist = decoded
} catch {
  fail("cannot parse \(input.path): \(error)")
}

guard
  let version = plist["CFBundleShortVersionString"] as? String,
  version.wholeMatch(of: /(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)/) != nil
else {
  fail("CFBundleShortVersionString must be a semantic release version")
}

let source = """
  // Generated from Resources/Dopa-Info.plist. Do not edit.
  extension DopaProtocol {
    public static let appVersion = "\(version)"
  }

  """

do {
  try source.write(to: output, atomically: true, encoding: .utf8)
} catch {
  fail("cannot write \(output.path): \(error)")
}
