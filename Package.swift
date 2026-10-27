// swift-tools-version: 6.2
import PackageDescription

// Apple platforms build Hub.xcodeproj (Hub-Local.xcworkspace for the checkouts next to this one). On Linux this
// package builds the same app folder, Hub/, as an executable on v57/SwiftUI's GTK backend:
//
//     V57_LOCAL=1 swift build --product Hub
//
// Hub's own packages come from the checkouts next to this one, as in the Xcode project (../../HubService/HubService,
// ../../Core/HubServer, ../../Channel/ChannelSwift). The v57 packages (SwiftUI, Component, Vault, Platform) come
// from GitHub's main branch, or from ~/Developer/v57 with `V57_LOCAL=1`.

#if os(Linux) || os(Windows)
let local = Context.environment["V57_LOCAL"] != nil
func v57(_ name: String) -> Package.Dependency {
  local ? .package(path: "../../../v57/\(name)") : .package(url: "https://github.com/v57/\(name).git", branch: "main")
}

let package = Package(
  name: "Hub",
  products: [.executable(name: "Hub", targets: ["Hub"])],
  dependencies: [
    .package(path: "../../HubService/HubService"),
    .package(path: "../../Channel/ChannelSwift"),
    .package(path: "../../Core/HubServer"),
    v57("SwiftUI"), v57("Component"), v57("Vault"), v57("Platform"),
  ],
  targets: [
    .executableTarget(
      name: "Hub",
      dependencies: [
        .product(name: "HubService", package: "HubService"),
        .product(name: "HubUI", package: "HubService"),
        .product(name: "Channel", package: "ChannelSwift"),
        .product(name: "HubServer", package: "HubServer"),
        .product(name: "SwiftUI", package: "SwiftUI"),
        .product(name: "CryptoKit", package: "SwiftUI"),
        .product(name: "SwiftUIPortability", package: "SwiftUI"),
        .product(name: "ComponentKit", package: "Component"),
        .product(name: "VaultKit", package: "Vault"),
        .product(name: "VaultHub", package: "Vault"),
        .product(name: "PlatformPower", package: "Platform"),
        .product(name: "PlatformSystem", package: "Platform"),
      ],
      path: "Hub",
      exclude: ["Info.plist", "Resources"],
      swiftSettings: [
        .swiftLanguageMode(.v5),
        .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("BareSlashRegexLiterals"),
        // What Apple's SDK imports implicitly with SwiftUI and Foundation (Combine, Observation, URLSession).
        .unsafeFlags(
          ["Combine", "Observation", "FoundationNetworking", "SwiftUIPortability"].flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
      ]),
  ]
)
#else
let package = Package(name: "Hub", products: [], targets: [])
#endif
