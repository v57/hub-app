// swift-tools-version: 6.2
import PackageDescription

// The Hub app, all of it but its entry point (Sources/Hub/HubMain.swift): Hub.xcodeproj (at the repository's root)
// builds that file into Hub.app and Hub Pro.app with Resources (icons, assets, Info.plists, entitlements) and the
// packet tunnel extension; on Linux and Windows the Hub target below does, on v57/SwiftUI's GTK backend:
//
//     cd App && V57_LOCAL=1 swift build --product Hub
//
// Hub's own packages (HubService, HubServer, ChannelSwift) and the v57 packages (Component, Vault, Platform, SwiftUI)
// come from GitHub's main branch, or with `V57_LOCAL=1` from the checkouts next to this one: ~/Developer/Hub/… and
// ~/Developer/v57/… (in Xcode, open Hub-Local.xcworkspace instead).

let local = Context.environment["V57_LOCAL"] != nil
/// A Hub package: GitHub's main branch, or its checkout at `path` in ~/Developer/Hub.
func hub(_ name: String, _ path: String) -> Package.Dependency {
  local ? .package(path: "../../../\(path)") : .package(url: "https://github.com/v57/\(name).git", branch: "main")
}
/// A v57 package: GitHub's main branch, or its checkout in ~/Developer/v57.
func v57(_ name: String) -> Package.Dependency {
  local ? .package(path: "../../../../v57/\(name)") : .package(url: "https://github.com/v57/\(name).git", branch: "main")
}

/// The vault isn't built for tvOS and visionOS (the code checks `canImport(VaultHub)`).
let vault = TargetDependencyCondition.when(platforms: [.macOS, .iOS, .linux, .windows])

let package = Package(
  name: "HubApp",
  platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v18), .visionOS(.v2)],
  products: [.library(name: "HubApp", targets: ["HubApp"])],
  dependencies: [
    hub("HubService", "HubService/HubService"), hub("ChannelSwift", "Channel/ChannelSwift"),
    hub("HubServer", "Core/HubServer"), v57("Component"), v57("Vault"), v57("Platform"),
  ],
  targets: [
    .target(
      name: "HubApp",
      dependencies: [
        .product(name: "HubService", package: "HubService"),
        .product(name: "HubUI", package: "HubService"),
        .product(name: "Channel", package: "ChannelSwift"),
        .product(name: "HubServer", package: "HubServer"),
        .product(name: "ComponentKit", package: "Component"),
        .product(name: "VaultKit", package: "Vault", condition: vault),
        .product(name: "VaultHub", package: "Vault", condition: vault),
        .product(name: "PlatformPower", package: "Platform"),
        .product(name: "PlatformSystem", package: "Platform"),
      ],
      // As the Xcode target had it: Swift 6 with the project's upcoming features that Swift 6 doesn't turn on itself.
      swiftSettings: [
        .swiftLanguageMode(.v6), .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
      ]),
    // The app's logic that needs no host app (the screenshot UI test stays in the Xcode project's Tests target).
    .testTarget(
      name: "HubAppTests", dependencies: ["HubApp", .product(name: "HubService", package: "HubService")],
      swiftSettings: [
        .swiftLanguageMode(.v5), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ]),
  ]
)

#if os(Linux) || os(Windows)
// Off Apple platforms SwiftUI, CryptoKit and the APIs Apple's SDK adds are v57/SwiftUI's. Only here: on Apple
// platforms the app uses Apple's SwiftUI, and v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode
// resolves. Never SwiftUI's Network stand-in: it makes canImport(Network) true in ChannelSwift and HubService.
package.dependencies += [v57("SwiftUI")]
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5),
  .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("BareSlashRegexLiterals"),
  // What Apple's SDK imports implicitly with SwiftUI and Foundation (Combine, Observation, URLSession).
  .unsafeFlags(
    ["Combine", "Observation", "FoundationNetworking", "SwiftUIPortability"].flatMap {
      ["-Xfrontend", "-import-module", "-Xfrontend", $0]
    }),
]
for target in package.targets where target.name == "HubApp" {
  target.dependencies += [
    .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "CryptoKit", package: "SwiftUI"),
    .product(name: "SwiftUIPortability", package: "SwiftUI"),
  ]
  target.swiftSettings = appSettings
}
// The entry point, Sources/Hub/HubMain.swift, which the Xcode project builds on Apple platforms.
package.targets.append(
  .executableTarget(
    name: "Hub", dependencies: ["HubApp", .product(name: "SwiftUI", package: "SwiftUI")], swiftSettings: appSettings))
package.products.append(.executable(name: "Hub", targets: ["Hub"]))
#endif
