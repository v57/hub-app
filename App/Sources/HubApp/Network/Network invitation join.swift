import Foundation
import HubService
import Observation

enum NativeJoinPresentation {
  static func progress(_ state: NativeJoinProgressState?) -> String {
    switch state {
    case .validating: String(localized: "Validating invitation…")
    case .staging: String(localized: "Preparing secure identity…")
    case .awaitingVPNConsent: String(localized: "Waiting for VPN approval…")
    case .startingTunnel: String(localized: "Starting secure tunnel…")
    case .rendezvous: String(localized: "Finding direct connection…")
    case .connected, .binding: String(localized: "Enrolling this device…")
    case .activating: String(localized: "Activating Hub Network…")
    case .recovering: String(localized: "Recovering previous join…")
    case .awaitingApproval: String(localized: "Waiting for an owner’s approval…")
    case nil: String(localized: "Joining…")
    }
  }

  static func error(_ error: Error, limit: Int = 240) -> String {
    let fallback = String(localized: "Hub Network join failed. Try the invitation again.")
    let raw: String
    if let invitation = error as? NetworkInvitationError {
      raw = invitation.message
    } else if let native = error as? NativeJoinError {
      raw = native.errorDescription ?? fallback
    } else if let agent = error as? HubNetDaemon.Failure {
      raw = agent.errorDescription ?? fallback
    } else {
      raw = fallback
    }
    let singleLine = sanitizeCause(raw)
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = singleLine.isEmpty ? fallback : singleLine
    guard safe.count > limit else { return safe }
    return String(safe.prefix(max(0, limit - 1))) + "…"
  }

  static func sanitizeCause(_ value: String, secrets: [String] = []) -> String {
    var result = value
    for secret in secrets where !secret.isEmpty {
      result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    result = result.replacingOccurrences(
      of: #"hub://net/join/[A-Za-z0-9_-]+"#,
      with: "[redacted invitation]", options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: #"\b[A-Za-z0-9_-]{32,}\b"#,
      with: "[redacted]", options: .regularExpression
    )
    let line = result.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? "Unknown safe cause." : String(line.prefix(160))
  }
}

/// An invitation as a link: `hub://join/<code>` puts a device on the hub's network, `hub://browse/<code>` does that and
/// switches it to the inviting device's internet (Add a Device's Use This Mac's Internet, H-035). The code is the same
/// signed invitation; the mode is outside it, so the node and older parsers see the usual code.
enum NetworkInvitationLink {
  static let browsePrefix = "hub://browse/"

  /// The invitation's own link or code, and whether it's for browsing
  static func parse(_ text: String) -> (link: String, browse: Bool) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix(browsePrefix) else { return (value, false) }
    return (NetworkInvitationParser.urlPrefix + value.dropFirst(browsePrefix.count), true)
  }

  /// `link` (hub://join/… or a bare code) as a browse link
  static func browse(_ link: String) -> String {
    let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = value.hasPrefix(NetworkInvitationParser.urlPrefix) ? String(value.dropFirst(NetworkInvitationParser.urlPrefix.count)) : value
    return browsePrefix + code
  }

  /// Decodes either kind
  static func decode(_ text: String) throws -> DecodedNetworkInvitation {
    try NetworkInvitationParser.decode(parse(text).link)
  }
}

@MainActor
@Observable
final class NetworkInvitationRouter {
  static let main = NetworkInvitationRouter()

  private(set) var pendingInput = ""

  func open(_ url: URL) {
    let link = url.absoluteString
    guard link.hasPrefix(NetworkInvitationParser.urlPrefix) || link.hasPrefix(NetworkInvitationLink.browsePrefix) else {
      return
    }
    pendingInput = link
  }

  /// The pending link is for browsing through the inviting device's internet
  var pendingIsBrowse: Bool { NetworkInvitationLink.parse(pendingInput).browse }

  func consume() -> String {
    defer { pendingInput = "" }
    return pendingInput
  }
}
