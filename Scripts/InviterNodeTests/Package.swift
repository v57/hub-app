// swift-tools-version:6.0
// Drives PacketTunnelExtension sources (symlinked) outside the extension: CoordinatorClient and LinkManager against a real
// hub-net-node, the inviter's bootstrap admission and the bootstrap peers' route claims. Run with ./run.sh.
import PackageDescription

let settings: [SwiftSetting] = [
  // The extension target's SWIFT_APPROACHABLE_CONCURRENCY
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
  name: "InviterNodeTests",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../../../../HubService/HubService"),
    // The local ChannelSwift HubService builds against (as in the local Xcode workspace), not its pinned GitHub copy
    .package(path: "../../../../Channel/ChannelSwift"),
  ],
  targets: [
    .target(name: "InviterNode", swiftSettings: settings),
    .target(name: "InviterBootstrap", dependencies: [.product(name: "HubService", package: "HubService")], swiftSettings: settings),
    .testTarget(
      name: "InviterNodeTests",
      dependencies: ["InviterNode", "InviterBootstrap", .product(name: "HubService", package: "HubService")],
      swiftSettings: settings
    ),
  ],
  swiftLanguageModes: [.v5]
)
