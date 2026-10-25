import Foundation
import HubService

extension InviterNodeClient {
  /// Registers `identity` as the inviter, signing challenges with it and logging to the extension diagnostics
  convenience init(
    nodeEndpoint: String,
    identity: KeyChain,
    probe: @escaping (String, Data) async throws -> Void,
    candidates: @escaping () -> Candidate?,
    onBootstrap: @escaping (BootstrapEvent) async -> Void,
    onStatusChange: @escaping (Bool) -> Void
  ) {
    self.init(
      nodeEndpoint: nodeEndpoint,
      serviceKey: identity.publicKey(),
      sign: { try HubNetworkCrypto.signBytes($0, domain: Self.registrationDomain, key: identity) },
      probe: probe,
      candidates: candidates,
      onBootstrap: onBootstrap,
      onStatusChange: onStatusChange,
      log: { extensionDiagnostics($0) }
    )
  }
}
