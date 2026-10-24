//
//  ConnectSheets.swift
//  Hub
//
//  Connect to a Hub: an address, and for a new hub-server its pairing code, which makes this device its first owner,
//  or an invitation to a hub's private network, in one field. On iOS it scans the QR code the other device shows.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

/// One field for what the other side gave you: a hub's address (with, for a new hub, the pairing code that makes
/// this device its first owner), a hub://pair link that carries both, or a Hub Network invitation (hub://join/… or
/// its code), which puts this device on the hub's private network
struct ConnectSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  @State private var input = NetworkInvitationRouter.main.pendingInput.isEmpty ? "" : NetworkInvitationRouter.main.consume()
  @State private var code = ""
  @State private var pairing = HubPairing()
  @State private var nets = HubNets.main
  @State private var joining = false
  @State private var joinError: String?
  @State private var scanning = false
  @State private var scanError: String?

  /// What the field holds
  private enum Entry {
    case empty, address(URL), invitation, badInvitation(String), unknown
  }

  private var entry: Entry {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .empty }
    do {
      _ = try NetworkInvitationParser.decode(text)
      return .invitation
    } catch let error as NetworkInvitationError {
      // A hub://join link, or a code that decoded far enough to be one (an address never has its key and signature)
      if text.hasPrefix(NetworkInvitationParser.urlPrefix) || [.expired, .invalidTime, .invalidSignature].contains(error.code) {
        return .badInvitation(error.message)
      }
    } catch {}
    return URL(hubAddress: text).map(Entry.address) ?? .unknown
  }

  private var isInvitation: Bool {
    switch entry {
    case .invitation, .badInvitation: true
    default: false
    }
  }

  private var isWorking: Bool { joining || pairing.state.isWorking }

  var body: some View {
    KitSheet(
      title: "Connect to a Hub",
      meta: "A hub's address and, for a new hub, its pairing code, or an invitation to a hub's network from its owner.",
      systemImage: "hexagon", hue: .accent, status: isWorking ? .working : .idle
    ) {
      QRScanCard(
        title: "Scan Code", help: "The pairing code a hub shows, or an invitation", scanning: $scanning, error: scanError
      ) { text in
        if accept(text) {
          scanning = false
          scanError = nil
        } else {
          scanError = "Not a pairing code or an invitation"
        }
      }
      FormCard(footer: isInvitation ? "Invitations work once, for seven days." : nil) {
        FormRow(
          isInvitation ? "Invitation" : "Address",
          help: isInvitation ? "Puts this \(KitDevice.name) on the hub's private network" : "mac.local, 192.168.1.5:1997 or an invitation",
          systemImage: isInvitation ? "person.badge.plus" : "network", hue: isInvitation ? .teal : .accent, error: inputError,
          field: TextField("Address or invitation", text: $input)
            .kitFont(.mono).autocorrectionDisabled()
            .onChange(of: input) {
              joinError = nil
              accept(input)
            }
        )
        if !isInvitation {
          FormRow(
            "Pairing code", help: "New hubs only: makes this \(KitDevice.name) an owner", systemImage: "number",
            field: TextField("ABC-123", text: $code)
              .kitFont(.mono).autocorrectionDisabled()
              .onChange(of: code) { if case .failed = pairing.state { pairing.reset() } }
          )
        }
      }
      // The fields explain themselves while they're edited
      .kitFormHelpWhileEditing()
      if joining {
        Text(NativeJoinPresentation.progress(nets.joinProgress?.state)).kitFont(.caption)
      } else if pairing.state != .idle {
        PairingStatusView(pairing).kitFont(.caption)
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
      Button(action) { Task { await go() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(!canGo || isWorking)
    }
    .kitSheetDismissDisabled(isWorking)
    // An invitation link opened while the sheet is up
    .onChange(of: NetworkInvitationRouter.main.pendingInput) { _, pending in
      if !pending.isEmpty, !isWorking { input = NetworkInvitationRouter.main.consume() }
    }
  }

  private var inputError: String? {
    if let joinError { return joinError }
    switch entry {
    case .badInvitation(let message): return message
    case .unknown: return "Not an address or an invitation"
    default: return nil
    }
  }

  private var action: String {
    if isInvitation { return joining ? "Joining…" : "Join" }
    return code.isEmpty ? "Connect" : "Pair"
  }

  private var canGo: Bool {
    switch entry {
    case .address, .invitation: true
    default: false
    }
  }

  private func go() async {
    switch entry {
    case .address(let url): await connect(url)
    case .invitation: await join()
    default: break
    }
  }

  private func connect(_ url: URL) async {
    let settings = Hub.Settings(name: url.name ?? input, address: url)
    guard let hub = await Hubs.main.connect(settings, code: code, named: false, pairing: pairing) else { return }
    if !code.isEmpty {
      // Leaves the result on screen for a moment
      try? await Task.sleep(for: .seconds(1.5))
    }
    Navigator.main.open(hub)
    dismiss()
  }

  private func join() async {
    joining = true
    joinError = nil
    defer { joining = false }
    do {
      let hub = try await HubNets.main.join(link: input.trimmingCharacters(in: .whitespacesAndNewlines))
      Navigator.main.open(hub, .network)
      dismiss()
    } catch {
      joinError = NativeJoinPresentation.error(error)
    }
  }

  /// Takes a hub://pair link (typed, pasted or scanned) apart into the address and code; keeps an invitation whole.
  /// False when the text is neither.
  @discardableResult
  private func accept(_ text: String) -> Bool {
    if let link = PairingLink(text) {
      input = link.address
      code = PairingCode.format(link.code)
      return true
    }
    guard (try? NetworkInvitationParser.decode(text)) != nil else { return false }
    if input != text { input = text }
    return true
  }
}

/// A pairing link opened from outside, as the sheet's item
struct PendingPairing: Identifiable {
  let link: PairingLink
  var id: String { link.address + link.code }
}

/// Pair with the hub a hub://pair link names: this device becomes its owner
struct PairingSheet: View {
  let link: PairingLink
  @State private var pairing = HubPairing()
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    let url = URL(hubAddress: link.address)
    KitSheet(
      title: "Pair with this hub?", meta: "This \(KitDevice.name) becomes the hub's owner.",
      systemImage: "hexagon", hue: .accent, status: pairing.state.isWorking ? .working : .idle
    ) {
      FormCard {
        FormRow("Address", systemImage: "network") {
          Text(url?.absoluteString ?? link.address).kitFont(.mono).lineLimit(1).truncationMode(.middle)
        }
        FormRow("Pairing code", systemImage: "number") {
          Text(PairingCode.format(link.code)).kitFont(.mono)
        }
      }
      if pairing.state != .idle {
        PairingStatusView(pairing).kitFont(.caption)
      }
    } footer: {
      if case .paired = pairing.state {
        Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      } else {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(pairing.state.isWorking)
        Button(pairing.state.isFailed ? "Try Again" : "Pair") { Task { await pair(url) } }
          .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
          .disabled(url == nil || pairing.state.isWorking)
      }
    }
    .kitSheetDismissDisabled(pairing.state.isWorking)
  }

  private func pair(_ url: URL?) async {
    guard let url else { return }
    let settings = Hub.Settings(name: url.name ?? link.address, address: url)
    guard let hub = await Hubs.main.connect(settings, code: link.code, named: false, pairing: pairing) else { return }
    Navigator.main.open(hub)
    // Leaves the result on screen for a moment
    try? await Task.sleep(for: .seconds(1.5))
    if case .paired = pairing.state { dismiss() }
  }
}

/// A row that opens the camera to read a QR code, on iOS; nothing elsewhere. `onScan` gets each new code and closes
/// the camera itself once it took one.
struct QRScanCard: View {
  let title: String
  let help: String
  @Binding var scanning: Bool
  var error: String?
  let onScan: (String) -> Void

  var body: some View {
#if os(iOS)
    FormCard {
      FormRow(title, help: help, systemImage: "qrcode.viewfinder", error: error) {
        Button(scanning ? "Close" : "Scan") { scanning.toggle() }.buttonStyle(.kit)
      }
    }
    if scanning {
      KitQRScanner(onScan: onScan).frame(height: 260)
    }
#endif
  }
}
#endif
