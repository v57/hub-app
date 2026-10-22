//
//  ConnectSheets.swift
//  Hub
//
//  Connect to a Hub (an address, and for a new hub-server its pairing code, which makes this device its first owner)
//  and Join Network (an invitation to a hub's private network).
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

struct ConnectSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var address = ""
  @State private var code = ""
  @State private var pairing = HubPairing()
  private var url: URL? { URL(hubAddress: address) }

  var body: some View {
    KitSheet(
      title: "Connect to a Hub",
      meta: "A hub on a Mac, a home server or a VPS. A new hub-server shows its pairing code in hub-launcher or `hub pair`.",
      systemImage: "hexagon", hue: .accent, status: pairing.state.isWorking ? .working : .idle
    ) {
      FormCard {
        FormRow("Address", help: "mac.local, 192.168.1.5:1997 or wss://hub.example.com", systemImage: "network") {
          TextField("Address", text: $address).kitField(mono: true).frame(maxWidth: 240)
            .onChange(of: address) { acceptLink(address) }
        }
        FormRow("Pairing code", help: "New hubs only: makes this \(KitDevice.name) an owner", systemImage: "number") {
          TextField("ABC-123", text: $code).kitField(mono: true).frame(maxWidth: 140)
            .onChange(of: code) { if case .failed = pairing.state { pairing.reset() } }
        }
      }
      if pairing.state != .idle {
        PairingStatusView(pairing).kitFont(.caption)
      }
    } footer: {
      Spacer()
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button(code.isEmpty ? "Connect" : "Pair") { Task { await connect() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(url == nil || pairing.state.isWorking)
    }
  }

  private func connect() async {
    guard let url else { return }
    let settings = Hub.Settings(name: url.name ?? address, address: url)
    guard let hub = await Hubs.main.connect(settings, code: code, named: false, pairing: pairing) else { return }
    if !code.isEmpty {
      // Leaves the result on screen for a moment
      try? await Task.sleep(for: .seconds(1.5))
    }
    Navigator.main.open(hub)
    dismiss()
  }

  private func acceptLink(_ text: String) {
    guard let link = PairingLink(text) else { return }
    address = link.address
    code = PairingCode.format(link.code)
  }
}

struct JoinNetworkSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var input = NetworkInvitationRouter.main.pendingInput.isEmpty ? "" : NetworkInvitationRouter.main.consume()
  @State private var joining = false
  @State private var error: String?
  @State private var nets = HubNets.main

  private var validationError: String? {
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    do {
      _ = try NetworkInvitationParser.decode(input)
      return nil
    } catch let invitationError as NetworkInvitationError {
      return invitationError.message
    } catch {
      return "Invalid invitation."
    }
  }

  var body: some View {
    KitSheet(
      title: "Join Network", meta: "An invitation from a hub's owner puts this \(KitDevice.name) on the hub's private network.",
      systemImage: "person.badge.plus", hue: .teal, status: joining ? .working : .idle
    ) {
      FormCard(footer: "Invitations work once, for seven days.") {
        FormRow("Invitation", systemImage: "link") {
          TextField("Invite code or hub:// link", text: $input).kitField(mono: true).frame(maxWidth: 280)
            .onChange(of: input) { error = nil }
        }
      }
      if joining {
        Text(NativeJoinPresentation.progress(nets.joinProgress?.state)).kitFont(.caption)
      } else if let message = error ?? validationError {
        Text(message).kitFont(.caption).foregroundStyle(Hue.red.text)
      }
    } footer: {
      Spacer()
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button(joining ? "Joining…" : "Join") { Task { await join() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(joining || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validationError != nil)
    }
  }

  private func join() async {
    joining = true
    error = nil
    defer { joining = false }
    do {
      let hub = try await HubNets.main.join(link: input)
      Navigator.main.open(hub, .network)
      dismiss()
    } catch {
      self.error = NativeJoinPresentation.error(error)
    }
  }
}
#endif
