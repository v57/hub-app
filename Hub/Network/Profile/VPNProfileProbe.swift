#if DEBUG
import Foundation
@preconcurrency import NetworkExtension

/// Debug probe for the system "Add VPN Configurations" consent prompt.
///
/// Launch with `HUB_VPN_PROBE=1` (or `=remove` to delete the profile). Each
/// launch reuses the existing Hub Network profile when there is one and only
/// creates it otherwise, then logs `[VPNPROBE]` lines to stdout.
@MainActor
enum VPNProfileProbe {
  nonisolated static var mode: String? {
    ProcessInfo.processInfo.environment["HUB_VPN_PROBE"]
  }

  static func run() async {
    do {
      let managers = try await NETunnelProviderManager.loadAllFromPreferences()
      let existing = managers.first {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?
          .providerBundleIdentifier == PacketTunnelController.providerBundleIdentifier
      }
      log("profiles=\(managers.count) existing=\(existing != nil)")
      if mode == "remove" {
        try await existing?.removeFromPreferences()
        log("removed")
        return
      }
      let manager = existing ?? NETunnelProviderManager()
      let tunnelProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol)
        ?? NETunnelProviderProtocol()
      tunnelProtocol.providerBundleIdentifier = PacketTunnelController.providerBundleIdentifier
      tunnelProtocol.serverAddress = "hub.invalid"
      var configuration = tunnelProtocol.providerConfiguration ?? [:]
      let launches = (configuration["probeLaunches"] as? Int ?? 0) + 1
      configuration["probeLaunches"] = launches
      tunnelProtocol.providerConfiguration = configuration
      manager.protocolConfiguration = tunnelProtocol
      manager.localizedDescription = PacketTunnelController.localizedDescription
      manager.isEnabled = true
      let started = ContinuousClock.now
      try await manager.saveToPreferences()
      try await manager.loadFromPreferences()
      log("saved \(existing == nil ? "created" : "reused") launches=\(launches) in \(ContinuousClock.now - started)")
    } catch {
      log("error \(error)")
    }
  }

  private static func log(_ message: String) {
    print("[VPNPROBE] \(message)")
    fflush(stdout)
  }
}
#endif
