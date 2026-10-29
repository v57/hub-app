import Foundation
import HubService
import Observation

enum NativeJoinPresentation {
  static func progress(_ state: NativeJoinProgressState?) -> String {
    switch state {
    case .validating: "Validating invitation…"
    case .staging: "Preparing secure identity…"
    case .awaitingVPNConsent: "Waiting for VPN approval…"
    case .startingTunnel: "Starting secure tunnel…"
    case .rendezvous: "Finding direct connection…"
    case .connected, .binding: "Enrolling this device…"
    case .activating: "Activating Hub Network…"
    case .recovering: "Recovering previous join…"
    case nil: "Joining…"
    }
  }

  static func error(_ error: Error, limit: Int = 240) -> String {
    let fallback = "Hub Network join failed. Try the invitation again."
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

@MainActor
@Observable
final class NetworkInvitationRouter {
  static let main = NetworkInvitationRouter()

  private(set) var pendingInput = ""

  func open(_ url: URL) {
    guard url.absoluteString.hasPrefix(NetworkInvitationParser.urlPrefix) else {
      return
    }
    pendingInput = url.absoluteString
  }

  func consume() -> String {
    defer { pendingInput = "" }
    return pendingInput
  }
}
