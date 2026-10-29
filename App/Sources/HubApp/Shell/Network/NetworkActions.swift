//
//  NetworkActions.swift
//  Hub
//
//  What the Network page, its overlays and the sidebar card do: the one switch, using another device's internet,
//  sharing an app and who may use it. The demo (`--demo`) changes the same state without a tunnel.
//

#if canImport(ComponentKit)
import SwiftUI
import HubService

extension HubNet {
  /// The one switch: this device on or off the hub's network. Off forgets nothing: the apps it shared and its internet
  /// sharing come back when it's turned on again.
  func setOn(_ on: Bool) async throws {
    let key = "network.paused.\(hub.settings.address.absoluteString)"
#if DEBUG
    if hub.isDemo {
      try? await Task.sleep(for: .seconds(on ? 1.5 : 0.4))
      if on {
        let saved = UserDefaults.standard.array(forKey: key) as? [Int] ?? [5432, 8096]
        demo(joined: true, tcp: Set(saved))
      } else {
        UserDefaults.standard.set(Array(sharedTcp), forKey: key)
        demo(joined: false, sharing: false, vpn: .some(nil), tcp: [])
      }
      return
    }
#endif
    struct Paused: Codable {
      var tcp: [Int]
      var udp: [Int]
      var internet: Bool
    }
    if on {
      try await joinNetwork(enabled: true)
      guard let data = UserDefaults.standard.data(forKey: key),
            let paused = try? JSONDecoder().decode(Paused.self, from: data) else { return }
      UserDefaults.standard.removeObject(forKey: key)
      for port in paused.tcp { try? await shareTcp(port: port, enabled: true) }
      for port in paused.udp { try? await shareUdp(port: port, enabled: true) }
      if paused.internet { try? await shareNetwork(enabled: true) }
    } else {
      let paused = Paused(tcp: sharedTcp.sorted(), udp: sharedUdp.sorted(), internet: isSharing)
      UserDefaults.standard.set(try? JSONEncoder().encode(paused), forKey: key)
      try await joinNetwork(enabled: false)
    }
  }

  /// Uses the internet of `device` (its agent key), stopping the one in use
  func useInternet(of device: NetDevice) async throws {
#if DEBUG
    if hub.isDemo {
      try? await Task.sleep(for: .seconds(1.2))
      demo(vpn: .some(devices.first { $0.key == device.gateway?.key }))
      NetworkRecents.main.use(device.id, hub: hub, internet: true)
      return
    }
#endif
    guard let gateway = devices.first(where: { $0.key == device.gateway?.key || $0.key == device.id }) else {
      throw HubNetError.deviceUnavailable
    }
    try await vpn(through: gateway)
    NetworkRecents.main.use(device.id, hub: hub, internet: true)
  }

  /// Back to this device's own internet
  func stopUsingInternet() async throws {
#if DEBUG
    if hub.isDemo {
      try? await Task.sleep(for: .seconds(0.4))
      demo(vpn: .some(nil))
      return
    }
#endif
    try await disableVpn()
  }

  /// Whether to use this device's own internet while the device whose internet it uses doesn't answer
  func setFallback(_ fallsBack: Bool) async throws {
#if DEBUG
    if hub.isDemo {
      demo(fallsBack: fallsBack)
      return
    }
#endif
    try await setFallsBack(fallsBack)
  }

  /// Lets the hub's devices use this device's internet, or stops
  func shareInternet(_ enabled: Bool) async throws {
#if DEBUG
    if hub.isDemo {
      demo(sharing: enabled)
      return
    }
#endif
    try await shareNetwork(enabled: enabled)
  }

  /// Shares an app's port with the hub's devices, named for the lists, or stops sharing it
  func share(app name: String?, port: Int, udp: Bool = false, enabled: Bool) async throws {
    if let name, !name.isEmpty { NetworkAppNames.main.set(name, port: port) }
#if DEBUG
    if hub.isDemo {
      var ports = sharedTcp
      if enabled { ports.insert(port) } else { ports.remove(port) }
      demo(tcp: ports)
      return
    }
#endif
    if udp {
      try await shareUdp(port: port, enabled: enabled)
    } else {
      try await shareTcp(port: port, enabled: enabled)
    }
  }
}

extension Hub {
  /// Who may use a shared app
  func setAccess(_ policy: HubNetworkPolicy, of app: NetApp) async throws {
#if DEBUG
    if isDemo {
      HubDemo.setPolicy(policy, share: app.id, hub: self)
      return
    }
#endif
    guard let resource = app.resource else { return }
    try await updateNetworkPolicy(resourceId: resource.resourceId, policy: policy)
  }

  /// Ends every connection to a shared app; devices still allowed connect again
  func disconnectEveryone(from app: NetApp) async throws {
    guard let resource = app.resource, !isDemo else { return }
    try await revokeNetworkResource(resourceId: resource.resourceId)
  }
}

extension Error {
  /// One readable line for a caption: what went wrong in Hub Network
  var networkLine: String {
    if self is CancellationError { return "This took too long. Try again." }
    let message = localizedDescription.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return String(message.prefix(240))
  }
}
#endif
