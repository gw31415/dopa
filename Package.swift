// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Dopa",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "dopa", targets: ["DopaCLI"]),
    .executable(name: "dopa-daemon", targets: ["DopaDaemonCLI"]),
    .executable(name: "dopa-ui", targets: ["DopaUI"]),
    .library(name: "DopaProtocol", targets: ["DopaProtocol"]),
    .library(name: "DopaClient", targets: ["DopaClient"]),
  ],
  targets: [
    .target(
      name: "CDopa",
      linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
    .target(name: "DopaProtocol"),
    .target(name: "DopaClient", dependencies: ["DopaProtocol"]),
    .target(name: "DopaAuthorization", linkerSettings: [.linkedFramework("Security")]),
    .target(name: "DopaCore", dependencies: ["CDopa", "DopaProtocol", "DopaAuthorization"]),
    .target(name: "DopaUIModel", dependencies: ["DopaClient", "DopaProtocol", "DopaAuthorization"]),
    .executableTarget(name: "DopaUI", dependencies: ["DopaUIModel", "CDopa"]),
    .target(name: "DopaManagement", dependencies: ["DopaClient", "DopaProtocol"]),
    .executableTarget(name: "DopaCLI", dependencies: ["DopaClient", "DopaProtocol"]),
    .executableTarget(name: "DopaDaemonCLI", dependencies: ["DopaCore", "DopaManagement", "DopaClient", "DopaProtocol"]),
    .executableTarget(
      name: "DopaTestHarness", dependencies: ["DopaCore", "DopaClient", "DopaProtocol"], path: "Tests/DopaTestHarness"),
    .testTarget(name: "DopaCoreTests", dependencies: ["DopaCore", "DopaTestHarness", "DopaClient", "DopaProtocol"]),
    .testTarget(name: "DopaProtocolTests", dependencies: ["DopaProtocol"]),
    .testTarget(name: "DopaClientTests", dependencies: ["DopaClient", "DopaProtocol"]),
    .testTarget(name: "DopaUIModelTests", dependencies: ["DopaUIModel", "DopaProtocol", "DopaAuthorization"]),
    .testTarget(name: "DopaUITests", dependencies: ["DopaUI", "DopaUIModel", "DopaProtocol"]),
    .testTarget(name: "DopaAuthorizationTests", dependencies: ["DopaAuthorization"]),
    .testTarget(name: "DopaManagementTests", dependencies: ["DopaManagement", "DopaProtocol"]),
    .testTarget(name: "DopaCLITests", dependencies: ["DopaCLI", "DopaDaemonCLI"]),
  ]
)
