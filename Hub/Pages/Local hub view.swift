//
//  Local hub view.swift
//  Hub
//
//  Turns the hub this device runs on and off, shows where others reach it, who is connected, and pairing codes.
//

#if canImport(HubServer)
import SwiftUI
import HubServer
import HubUI
import CoreImage.CIFilterBuiltins

struct LocalHubView: View {
  @State private var hub = LocalHub.main
  @State private var portText = ""
  @State private var copied: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        if let error = hub.error {
          Text(error).foregroundStyle(.red).transition(.blurReplace)
        }
        if hub.isRunning {
          addresses
          pairing
          network
          connections
        } else if !hub.isStarting {
          port
        }
        limits
      }.padding().frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
    }.navigationTitle("This Device")
      .toolbarTitleDisplayMode(.inline)
      .animation(.home, value: hub.status)
      .animation(.home, value: hub.pairing)
      .animation(.home, value: hub.error)
      .task { hub.refreshAddresses() }
  }

  var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: Binding(get: { hub.isEnabled }, set: { enabled in Task { await hub.setEnabled(enabled) } })) {
        Text("Run a Hub on this device").font(.title3.bold())
      }.toggleStyle(.switch).disabled(hub.isStarting)
      Text("Other devices on your network connect to this one, and this app is the hub's owner. Services, devices and permissions work as on any hub.")
        .secondary()
      if hub.isRunning, let name = hub.status.name {
        Label("\(name) is running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      } else if hub.isStarting {
        Label("Starting…", systemImage: "hourglass")
      }
    }
  }

  var port: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Port").font(.headline)
      TextField("1997", text: $portText)
        .onAppear { portText = "\(hub.port)" }
        .onChange(of: portText) {
          if let port = UInt16(portText), port > 0 { hub.port = port }
        }
#if os(iOS)
        .keyboardType(.numberPad)
#endif
        .font(.body.monospaced()).frame(maxWidth: 160)
#if !os(tvOS)
        .textFieldStyle(.roundedBorder)
#endif
      Text("Other devices dial this device's address with this port.").secondary()
    }
  }

  var addresses: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Address").font(.headline)
      let port = hub.status.port ?? hub.port
      if hub.addresses.isEmpty {
        Text("Connect to Wi-Fi or Ethernet so other devices can reach this hub.").secondary()
      }
      ForEach(hub.addresses, id: \.self) { address in
        copyRow("\(address):\(port)")
      }
      Text("On this device: 127.0.0.1:\(String(port))").secondary()
      if let key = hub.status.hubKey {
        Text("Hub key \(key.dropFirst(16).prefix(12))…").secondary().textSelection(.enabled)
      }
    }
  }

  @ViewBuilder
  var pairing: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pair another device").font(.headline)
      if let code = hub.pairing {
        Text(code.code).font(.system(size: 34, weight: .semibold, design: .monospaced)).textSelection(.enabled)
        Text("Valid until \(code.expires.formatted(date: .omitted, time: .shortened)), once. In the Hub app on the other device, open **Connect to a Hub** and enter \(hub.networkAddress ?? "this device's address") and this code, or scan the code below.")
          .secondary()
        if let link = hub.pairingLink {
          QRCodeView(text: link.absoluteString).frame(width: 200, height: 200)
          HStack {
            copyButton(link.absoluteString, title: "Copy Link")
#if !os(tvOS)
            ShareLink(item: link) { Label("Share", systemImage: "square.and.arrow.up") }
#endif
          }.buttonStyle(.bordered)
        }
        HStack {
          AsyncButton("New Code") { await hub.newPairingCode() }
          Button("Hide") { hub.hidePairingCode() }
        }.buttonStyle(.bordered)
      } else {
        if hub.didPair {
          Label("Paired. The other device is an owner now.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
        Text("A pairing code makes another device an owner of this hub, for example your iPad or Mac.").secondary()
        AsyncButton("Show Pairing Code") { await hub.newPairingCode() }.buttonStyle(.bordered)
      }
    }
  }

  /// The hub hosts a Hub Network like any hub: this device's agent is its owner and inviter
  @ViewBuilder
  var network: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Hub Network").font(.headline)
      Text("Devices you invite join a private network hosted by this hub. Set its node and create invitations here; this device's own network extension is the first member and the inviter.")
        .secondary()
      if (hub.status.port ?? hub.port) != 1997 {
        Label("Members reach the hub on port 1997 over the network. Use port 1997 to host one.", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
      if let localHub = Hubs.main.list.first(where: { $0.settings.address == hub.localURL }) {
        NavigationLink {
          HubNetworkView().hub(localHub)
        } label: {
          Label("Open Hub Network", systemImage: "network")
        }.buttonStyle(.bordered)
      }
    }
  }

  var connections: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Connected (\(hub.status.connections))").font(.headline)
      ForEach(hub.status.peers) { peer in
        HStack(alignment: .firstTextBaseline) {
          Image(systemName: peer.services > 0 ? "server.rack" : "iphone")
          VStack(alignment: .leading) {
            Text(peer.device ?? peer.name ?? peer.key.map { "Key \($0.dropFirst(16).prefix(8))…" } ?? "Anonymous")
            Text([peer.device != nil ? peer.name : nil, peer.address, peer.services > 0 ? "\(peer.services) services" : nil]
              .compactMap { $0 }.joined(separator: " · ")).secondary()
          }
        }
      }
    }
  }

  var limits: some View {
    VStack(alignment: .leading, spacing: 8) {
#if os(iOS) || os(visionOS)
      Text("While Hub is open").font(.headline)
      Text("iOS pauses this hub shortly after Hub leaves the screen, and it starts again when you come back. To keep serving, leave Hub open: Farm keeps the screen awake. iOS asks to allow Hub on the local network the first time.")
        .secondary()
#if os(iOS)
      NavigationLink("Open Farm") { FarmView() }.buttonStyle(.bordered)
#endif
#elseif os(tvOS)
      Text("The hub runs while Hub is open.").secondary()
#else
      Text("The hub runs while Hub is open. Farm keeps this Mac from sleeping.").secondary()
      NavigationLink("Open Farm") { FarmView() }.buttonStyle(.bordered)
#endif
    }
  }

  func copyRow(_ text: String) -> some View {
    HStack {
      Text(text).font(.body.monospaced()).textSelection(.enabled)
      Spacer(minLength: 0)
      copyButton(text, title: "Copy").buttonStyle(.bordered)
    }
  }

  func copyButton(_ text: String, title: String) -> some View {
    Button(copied == text ? "Copied" : title, systemImage: copied == text ? "checkmark" : "doc.on.doc") {
      text.copyToClipboard()
      copied = text
      Task {
        try? await Task.sleep(for: .seconds(2))
        if copied == text { copied = nil }
      }
    }
  }
}

/// The Home card for the hub this device runs
struct LocalHubCard: View {
  @State private var hub = LocalHub.main
  var body: some View {
    ZStack {
      Text("This Device").note()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Text(subtitle)
        .secondary()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }.blockBackground()
  }
  var subtitle: String {
    if hub.isRunning {
      let count = hub.status.connections
      return "Hub on port \(hub.status.port ?? hub.port) · \(count) connected"
    }
    if hub.isStarting { return "Starting the hub…" }
    if hub.isEnabled, hub.error != nil { return "The hub couldn't start" }
    return "Run a Hub on this device"
  }
}

/// A QR code of the text, black on white
struct QRCodeView: View {
  let text: String
  var body: some View {
    if let image = Self.image(text) {
      Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
  }
  static func image(_ text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    return CIContext().createCGImage(scaled, from: scaled.extent)
  }
}
#endif
