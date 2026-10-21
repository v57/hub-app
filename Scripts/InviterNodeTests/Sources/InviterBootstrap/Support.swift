import Foundation

// What Inviter.swift takes from the extension's other files
extension ISO8601DateFormatter {
  static func hubNetworkDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
