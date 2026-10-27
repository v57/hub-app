//
//  Pairing.swift
//  Hub
//
//  Adding a hub: a typed address read as a hub URL, the name it shows until the hub names itself, pairing with a code,
//  and `hub://pair` links opened from outside.
//

import Foundation
import HubService
import HubUI

/// `hub://pair` links opened from outside (a QR scanned with the camera, `hub pair` in a terminal), which the window
/// asks about in a pairing sheet
@MainActor
@Observable
final class PairingRouter {
  static let main = PairingRouter()
  private(set) var pending: PairingLink?
  /// Whether the URL was a pairing link (a malformed one is dropped)
  @discardableResult
  func open(_ url: URL) -> Bool {
    guard PairingLink.isPairingLink(url.absoluteString) else { return false }
    pending = PairingLink(url: url)
    return true
  }
  func dismiss() {
    pending = nil
  }
}

extension PairingState {
  var isFailed: Bool {
    if case .failed = self { true } else { false }
  }
}

extension Hubs {
  /// Adds the hub and, with a pairing code, pairs with it so this device becomes an owner. A hub added for a pairing that
  /// failed is removed again with its pinned key, so a wrong address or code leaves nothing behind.
  /// - Returns: the hub, or `nil` when pairing failed (`pairing.state` says why)
  @discardableResult
  func connect(_ settings: Hub.Settings, code: String, named: Bool, pairing: HubPairing) async -> Hub? {
    guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return insert(with: settings) }
    guard PairingCode.normalize(code) != nil else {
      pairing.fail(.malformedCode)
      return nil
    }
    let isNew = !list.contains { $0.id == settings.id }
    let hub = insert(with: settings)
    guard let result = await pairing.pair(hub.client, code: code) else {
      if isNew {
        hub.client.hubKeys.forget(settings.address)
        remove(with: settings)
      }
      return nil
    }
    if !named, let name = result.name, !name.isEmpty {
      hub.settings.name = name
      save()
    }
    return hub
  }
}

extension URL {
  /// A typed hub address (`192.168.1.5:1997`, `mac.local`, `wss://hub.example.com`) as a WebSocket URL
  init?(hubAddress address: String) {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    // `192.168.1.5:1997` isn't a URL (a scheme can't start with a digit), so it's read as an authority
    guard var components = URLComponents(string: address) ?? URLComponents(string: "//" + address) else { return nil }
    components.hub()
    guard let url = components.url, !url.absoluteString.isEmpty else { return nil }
    self = url
  }
  /// A hub's name from its address: `apple.com` → Apple, `192.168.1.5:1998` → itself, `localhost:1998` → 1998
  var name: String? {
    guard let host = host() else { return nil }
    let dots = host.components(separatedBy: ".")
    if host.isIp {
      if let port, port != 1997 {
        return "\(host):\(port)"
      } else {
        return "\(host)"
      }
    } else if let port, dots.count == 1, port != 1997 {
      return port.description // localhost:1998 -> 1998
    } else {
      var name = host.secondDomain.capitalized
      let pathName = path().components(separatedBy: "/")
        .last!.components(separatedBy: "?")[0].capitalized
      if !pathName.isEmpty {
        name += " \(pathName)"
      }
      return name // apple.com -> Apple
    }
  }
}

private extension URLComponents {
  /// Fills in what a typed address leaves out: the host when it was read as a scheme or path, `ws` for an IP or a local
  /// name and `wss` otherwise, and port 1997 for `ws`
  mutating func hub() {
    if host == nil, !path.isEmpty || scheme != nil {
      var components = path.components(separatedBy: "/")
      if scheme != nil {
        host = scheme
        scheme = nil
        if let port = Int(components[0]) {
          self.port = port
          components.removeFirst()
        }
      } else {
        let host = components.removeFirst()
        if let port = Int(host) {
          self.port = port
          self.host = "localhost"
        } else {
          self.host = host
        }
      }
      if components.filter({ !$0.isEmpty }).count > 0 {
        path = "/" + components.joined(separator: "/")
      } else {
        path = ""
      }
    }
    if let host, !host.isEmpty {
      if scheme == nil {
        scheme = host.isIp || host.isLocal ? "ws" : "wss"
      }
      if port == nil && scheme == "ws" {
        port = 1997
      }
    }
  }
}

private extension String {
  var isIp: Bool {
    let ipv4Regex = /^((25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)$/
    let ipv6Regex = /^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$/
    return wholeMatch(of: ipv4Regex) != nil || self.wholeMatch(of: ipv6Regex) != nil
  }
  var isLocal: Bool {
    let components = components(separatedBy: ".")
    return components.count < 2 || components.last == "local" || components.last?.isEmpty ?? true
  }
  var secondDomain: String {
    let components = components(separatedBy: ".")
    guard components.count > 1 else { return self }
    return components[components.count - 2]
  }
}
