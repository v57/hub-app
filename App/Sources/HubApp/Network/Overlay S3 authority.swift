import Foundation

/// Pure-Swift overlay-S3 authority builder.
///
/// Hub Network reserves the `hub.invalid` DNS suffix for canonical resource
/// authorities. Built-in services (image/video encoder, etc.) consume ordinary
/// `URL` values constructed from a published share authority plus the runtime
/// port advertised by a live provider. No WireGuard or NetworkExtension code
/// belongs here: the active app-scoped packet-tunnel profile routes the
/// resulting host name through `hub-net`. Authorities follow the
/// `<display>-<resource-tag>.v1-<hub-tag>.hub.invalid` grammar.
enum HubNetworkOverlayS3 {
  /// Reserved Hub Network DNS suffix. Active profile resolves only this suffix.
  static let reservedSuffix = "hub.invalid"

  /// HTTP endpoint for an authorized overlay S3 share.
  ///
  /// - Parameters:
  ///   - resource: stable published network resource carrying canonical
  ///     `authority` (e.g. `s3-…-….v1-….hub.invalid`).
  ///   - provider: live provider advertising the runtime port bound to the
  ///     local S3 listener. Port MUST come from the provider, never a default.
  ///   - profile: active app-scoped profile. Used only to confirm the suffix
  ///     matches the reserved Hub Network namespace; no private material read.
  /// - Returns: `http://<authority>:<port>` URL safe to hand to ordinary
  ///   `URLSession`-based networking once the packet tunnel is connected.
  static func endpoint(
    for resource: HubNetworkResource,
    provider: HubNetworkProvider,
    activeProfile: HubNetworkProfileConfiguration
  ) throws -> URL {
    guard resource.authority.hasSuffix(".\(reservedSuffix)") else {
      throw HubNetworkOverlayS3Error.authorityOutsideReservedSuffix(resource.authority)
    }
    guard activeProfile.dnsSuffix == reservedSuffix else {
      throw HubNetworkOverlayS3Error.profileNotReservedSuffix(activeProfile.dnsSuffix)
    }
    guard provider.resourceId == resource.resourceId else {
      throw HubNetworkOverlayS3Error.providerForDifferentResource
    }
    guard provider.port > 0 else {
      throw HubNetworkOverlayS3Error.invalidPort(provider.port)
    }

    var components = URLComponents()
    // hub-s3 and hub-s3-local publish loopback HTTP listeners. Hub Network
    // supplies authenticated, encrypted transport below this application URL.
    components.scheme = "http"
    components.host = resource.authority
    components.port = Int(provider.port)
    guard let url = components.url else {
      throw HubNetworkOverlayS3Error.invalidAuthority(resource.authority)
    }
    return url
  }

  /// Append a presigned-style object path + query to an overlay endpoint.
  ///
  /// The encoder treats overlay URLs identically to public provider URLs: this
  /// helper exists only so callers can construct a full object URL without
  /// touching networking code when the packet tunnel is active.
  static func objectURL(
    endpoint: URL,
    key: String,
    queryItems: [URLQueryItem] = []
  ) throws -> URL {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw HubNetworkOverlayS3Error.invalidAuthority(endpoint.absoluteString)
    }
    let path = key.split(separator: "/").map(String.init).joined(separator: "/")
    components.path = path.isEmpty ? "/" : "/\(path)"
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    guard let url = components.url else {
      throw HubNetworkOverlayS3Error.invalidAuthority(endpoint.absoluteString)
    }
    return url
  }
}

enum HubNetworkOverlayS3Error: Error, Equatable {
  case authorityOutsideReservedSuffix(String)
  case profileNotReservedSuffix(String)
  case providerForDifferentResource
  case invalidPort(UInt16)
  case invalidAuthority(String)
}
