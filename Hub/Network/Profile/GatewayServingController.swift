import Foundation
import HubService

private struct GatewayAdvertisementRequest: Encodable, Sendable {
  let capability: GatewayCapability
  let endpoint: String
}

private struct GatewayRemovalRequest: Encodable, Sendable {
  let reason: String
}

/// Orders extension state and Hub capability mutations fail-closed.
///
/// Enable: extension first, advertisement second.
/// Disable: advertisement first, extension second.
@MainActor
final class GatewayServingController {
  private(set) var state: GatewayServingState = .disabled

  func setEnabled(
    _ enabled: Bool,
    hub: Hub,
    tunnel: PacketTunnelController
  ) async throws {
    if enabled {
      state = .enabling
      do {
        try await tunnel.restoreInstalledLocalMembership(hub: hub)
        try await tunnel.setGatewayServing(true)
        // Only the hub's machine runs its agent
        if hub.isOnHubMachine {
          hub.networkAppAgent.enable(tunnel: tunnel)
        }
        try await advertise(hub: hub)
        state = .available
      } catch {
        try? await tunnel.setGatewayServing(false)
        if hub.isOnHubMachine {
          hub.networkAppAgent.enable(tunnel: tunnel)
        }
        state = .unavailable
        throw error
      }
    } else {
      state = .disabling
      do {
        do {
          try await hub.client.send(
            "network/gateway/remove",
            GatewayRemovalRequest(reason: "provider_disabled")
          )
        } catch {
          // Gateway advertisements are connection-bound. If that profile or
          // advertisement is already gone, Hub has already performed the
          // requested remote cleanup and local disable must continue.
          guard Self.isAlreadyRemoved(error) else {
            throw GatewayServingControllerError.removalFailed(
              String(describing: error)
            )
          }
        }
        try await tunnel.setGatewayServing(false)
        if hub.isOnHubMachine {
          hub.networkAppAgent.enable(tunnel: tunnel)
        }
        state = .disabled
      } catch {
        state = .unavailable
        throw error
      }
    }
  }

  /// Tells the hub this device offers its internet. Advertisements are bound to the connection, so a new one sends
  /// it again; the extension keeps serving meanwhile, so the tunnel stays as it is.
  func advertise(hub: Hub) async throws {
    let capability = GatewayCapability(
      ipv4: true,
      ipv6: true,
      dns: true,
      metered: false,
      updatedAt: ISO8601DateFormatter.js.string(from: Date())
    )
    do {
      try await hub.client.send(
        "network/gateway/advertise",
        GatewayAdvertisementRequest(
          capability: capability,
          endpoint: try gatewayEndpoint()
        )
      )
    } catch {
      throw GatewayServingControllerError.advertisementFailed(
        String(describing: error)
      )
    }
  }

  private func gatewayEndpoint() throws -> String {
    let environment = ProcessInfo.processInfo.environment[
      "HUB_NETWORK_GATEWAY_ENDPOINT"
    ]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = environment.flatMap { $0.isEmpty ? nil : $0 }
      // The extension listens on 51820 while it serves the gateway (PacketTunnelWireGuardAdapter)
      ?? "\(ProcessInfo.processInfo.hostName):51820"
    guard value.lastIndex(of: ":") != nil else {
      throw GatewayServingControllerError.invalidEndpoint
    }
    return value
  }

  static func isAlreadyRemoved(_ error: Error) -> Bool {
    let message = String(describing: error).lowercased()
    return message.contains("agent profile not registered")
      || message.contains("gateway is not advertised by this connection")
  }
}

enum GatewayServingControllerError: Error, Equatable {
  case invalidEndpoint
  case advertisementFailed(String)
  case removalFailed(String)
}

extension GatewayServingControllerError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "Internet Gateway endpoint is invalid."
    case .advertisementFailed(let reason):
      "Could not advertise Internet Gateway: \(reason)"
    case .removalFailed(let reason):
      "Could not remove Internet Gateway: \(reason)"
    }
  }
}
