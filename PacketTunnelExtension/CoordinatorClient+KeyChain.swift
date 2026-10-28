import Foundation
import HubService

extension CoordinatorClient {
  /// Keeps `identity` present, signing challenges with it and logging to the extension diagnostics
  convenience init(
    nodeEndpoint: String,
    identity: KeyChain,
    probe: @escaping (String, Data) async throws -> Void,
    candidates: @escaping () async -> Candidate?,
    onBootstrap: @escaping (BootstrapEvent) async -> Void,
    onLink: @escaping (Envelope) async -> Void,
    onStatusChange: @escaping (Bool) -> Void
  ) {
    self.init(
      nodeEndpoint: nodeEndpoint,
      serviceKey: identity.publicKey(),
      sign: { try HubNetworkCrypto.signBytes($0, domain: Self.registrationDomain, key: identity) },
      probe: probe,
      candidates: candidates,
      onBootstrap: onBootstrap,
      onLink: onLink,
      onStatusChange: onStatusChange,
      log: { extensionDiagnostics($0) }
    )
  }
}
