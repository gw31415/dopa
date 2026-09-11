// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Dopa",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "dopa", targets: ["DopaCLI"])],
  targets: [
    .target(
      name: "CDopa",
      linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
    .target(name: "DopaCore", dependencies: ["CDopa"]),
    .executableTarget(name: "DopaCLI", dependencies: ["DopaCore"]),
    .executableTarget(
      name: "DopaTestHarness", dependencies: ["DopaCore"], path: "Tests/DopaTestHarness"),
    .testTarget(name: "DopaCoreTests", dependencies: ["DopaCore", "DopaTestHarness"]),
  ]
)
