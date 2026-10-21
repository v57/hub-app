//
//  Connect.swift
//  Hub
//
//  Created by Linux on 05.06.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
import HubService
import HubUI

/// `hub://pair` links opened from outside (a QR scanned with the camera, `hub pair` in a terminal), for the Connect to a
/// Hub views to pick up
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
  func consume() -> PairingLink? {
    defer { pending = nil }
    return pending
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
  @State private var router = PairingRouter.main
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
      .onAppear(perform: acceptPending)
      .onChange(of: router.pending) { acceptPending() }
  }
  func acceptLink(_ text: String) {
    guard let link = PairingLink(text) else { return }
    address = link.address
    code = PairingCode.format(link.code)
  }
  func acceptPending() {
    guard let link = router.consume() else { return }
    address = link.address
    code = PairingCode.format(link.code)
  }
}

#Preview {
  NavigationStack {
    ConnectView()
  }
}
