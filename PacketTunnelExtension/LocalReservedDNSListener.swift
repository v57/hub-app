import Foundation
import Network

/// UDP DNS endpoint used by scoped `hub.invalid` NetworkExtension settings.
///
/// Only matched Hub names reach this listener. It never forwards ordinary DNS;
/// those queries remain on macOS system resolvers.
final class LocalReservedDNSListener {
  static let port: NWEndpoint.Port = 53

  let address: Address
  private let resolver: DNS.Resolver
  private let queue = DispatchQueue(label: "dev.v57.hub.network.dns")
  private var listener: NWListener?

  init(profile: Profile) throws {
    address = try Address(overlay: profile.overlayIPv4Address)
    resolver = try DNS.Resolver(records: profile.dnsRecords ?? [])
  }

  func start() throws {
    let parameters = NWParameters.udp
    // mDNSResponder owns the wildcard UDP/53 socket on macOS. An exact
    // loopback listener can coexist and receives traffic addressed to it.
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(
      host: address.host,
      port: Self.port
    )
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receiveMessage { [weak self] data, _, _, _ in
      guard let self, let data, let response = resolver.response(to: data) else {
        connection.cancel()
        return
      }
      connection.send(
        content: response,
        contentContext: .defaultMessage,
        isComplete: true,
        completion: .contentProcessed { _ in connection.cancel() }
      )
    }
  }
}
