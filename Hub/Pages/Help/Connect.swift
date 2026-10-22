//
//  Connect.swift
//  Hub
//
//  Created by Linux on 05.06.26.
//

import SwiftUI
import HubService
import HubUI

/// `hub://pair` links opened from outside (a QR scanned with the camera, `hub pair` in a terminal), which
/// `PairingConfirmation` asks about
@MainActor
@Observable
final class PairingRouter {
  static let main = PairingRouter()
  private(set) var pending: PairingLink?
  /// Whether the URL was a pairing link (a malformed one is dropped)
  @discardableResult
  func open(_ url: URL) -> Bool {
    guard PairingLink.isPairingLink(url.absoluteString) else { return false }
    pending = PairingLink(url: url)
    return true
  }
  func dismiss() {
    pending = nil
  }
}

/// Asks to pair with the hub a `hub://pair` link names, in front of everything, and pairs on confirm
struct PairingConfirmation: View {
  @State private var router = PairingRouter.main
  @State private var pairing = HubPairing()
  var body: some View {
    ZStack {
      if let link = router.pending {
        Color.black.opacity(0.35).ignoresSafeArea()
          .onTapGesture { if !pairing.state.isWorking { close() } }
          .transition(.opacity)
        card(link).transition(.scale(scale: 0.9).combined(with: .opacity))
      }
    }.animation(.home, value: router.pending)
      .animation(.home, value: pairing.state)
      .onChange(of: router.pending) { pairing.reset() }
  }
  func card(_ link: PairingLink) -> some View {
    let url = URL(hubAddress: link.address)
    return VStack(alignment: .leading, spacing: 12) {
      Text("Pair with this hub?").font(.title3.bold())
      VStack(alignment: .leading, spacing: 4) {
        Text(url?.absoluteString ?? link.address).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
        Text("Pairing code \(PairingCode.format(link.code))").secondary()
      }
      if pairing.state == .idle {
        Text("This device becomes the hub's owner.").secondary()
      } else {
        PairingStatusView(pairing).font(.callout).lineLimit(3)
      }
      HStack {
        if case .paired = pairing.state {
          Spacer(minLength: 0)
          Button("Done") { close() }.buttonStyle(.borderedProminent)
        } else {
          Button("Cancel", role: .cancel) { close() }
            .buttonStyle(.bordered).disabled(pairing.state.isWorking)
          Spacer(minLength: 0)
          Button {
            Task { await pair(link, url: url) }
          } label: {
            Text(pairing.state.isFailed ? "Try Again" : "Pair").frame(minWidth: 80)
          }.buttonStyle(.borderedProminent).disabled(url == nil || pairing.state.isWorking)
        }
      }.controlSize(.large)
    }.padding(20).frame(maxWidth: 380)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
      .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
      .padding(16)
  }
  func pair(_ link: PairingLink, url: URL?) async {
    guard let url else { return }
    let settings = Hub.Settings(name: url.name ?? link.address, address: url)
    guard await Hubs.main.connect(settings, code: link.code, named: false, pairing: pairing) != nil else { return }
    // Leaves the result on screen for a moment
    try? await Task.sleep(for: .seconds(2))
    if router.pending == link, case .paired = pairing.state { close() }
  }
  func close() {
    router.dismiss()
    pairing.reset()
  }
}

extension PairingState {
  var isFailed: Bool {
    if case .failed = self { true } else { false }
  }
}

extension Hubs {
  /// Adds the hub and, with a pairing code, pairs with it so this device becomes an owner. A hub added for a pairing that
  /// failed is removed again with its pinned key, so a wrong address or code leaves nothing behind.
  /// - Returns: the hub, or `nil` when pairing failed (`pairing.state` says why)
  @discardableResult
  func connect(_ settings: Hub.Settings, code: String, named: Bool, pairing: HubPairing) async -> Hub? {
    guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return insert(with: settings) }
    guard PairingCode.normalize(code) != nil else {
      pairing.fail(.malformedCode)
      return nil
    }
    let isNew = !list.contains { $0.id == settings.id }
    let hub = insert(with: settings)
    guard let result = await pairing.pair(hub.client, code: code) else {
      if isNew {
        hub.client.hubKeys.forget(settings.address)
        remove(with: settings)
      }
      return nil
    }
    if !named, let name = result.name, !name.isEmpty {
      hub.settings.name = name
      save()
    }
    return hub
  }
}

extension URL {
  /// A typed hub address (`192.168.1.5:1997`, `mac.local`, `wss://hub.example.com`) as a WebSocket URL
  init?(hubAddress address: String) {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    // `192.168.1.5:1997` isn't a URL (a scheme can't start with a digit), so it's read as an authority
    guard var components = URLComponents(string: address) ?? URLComponents(string: "//" + address) else { return nil }
    components.hub()
    guard let url = components.url, !url.absoluteString.isEmpty else { return nil }
    self = url
  }
}

struct ConnectView: View {
  @Environment(\.dismiss) private var dismiss
  let hubs = Hubs.main
  @State var address: String = ""
  @State var name: String = ""
  @State var code: String = ""
  @State private var pairing = HubPairing()
  var url: URL? { URL(hubAddress: address) }
  var providedName: String? { name.isEmpty ? url?.name : name }
  var body: some View {
    VStack(alignment: .leading) {
      if let url {
        Text(url.absoluteString)
      }
      TextField("Address", text: $address).keyboard(style: .url)
        .onChange(of: address) { acceptLink(address) }
      if !address.isEmpty {
        TextField(url?.name ?? "Name", text: $name).transition(.blurReplace)
        TextField("Pairing code (new hub)", text: $code).transition(.blurReplace)
          .onChange(of: code) { if case .failed = pairing.state { pairing.reset() } }
      }
      if let url, let providedName {
        Button {
          Task {
            let settings = Hub.Settings(name: providedName, address: url)
            guard await hubs.connect(settings, code: code, named: !name.isEmpty, pairing: pairing) != nil else { return }
            self.name = ""
            self.address = ""
            self.code = ""
            if case .paired = pairing.state {
              try? await Task.sleep(for: .seconds(2))
            }
            dismiss()
          }
        } label: {
          Text(code.isEmpty ? "Connect" : "Pair")
        }.disabled(pairing.state.isWorking).transition(.blurReplace)
      }
      PairingStatusView(pairing)
    }.animation(.home, value: address.isEmpty)
      .navigationTitle("Connect to a Hub")
  }
  func acceptLink(_ text: String) {
    guard let link = PairingLink(text) else { return }
    address = link.address
    code = PairingCode.format(link.code)
  }
}

#Preview {
  NavigationStack {
    ConnectView()
  }
}
