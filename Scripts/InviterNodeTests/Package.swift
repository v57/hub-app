// swift-tools-version:6.0
// Drives PacketTunnelExtension/InviterNodeClient.swift (symlinked) against a real hub-net-node. Run with ./run.sh.
import PackageDescription

let settings: [SwiftSetting] = [
  // The extension target's SWIFT_APPROACHABLE_CONCURRENCY
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
  name: "InviterNodeTests",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "InviterNode", swiftSettings: settings),
    .testTarget(name: "InviterNodeTests", dependencies: ["InviterNode"], swiftSettings: settings),
  ],
  swiftLanguageModes: [.v5]
)
