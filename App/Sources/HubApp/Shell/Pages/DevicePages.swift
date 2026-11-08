//
//  DevicePages.swift
//  Hub
//
//  What this device does on its own: run a hub, share its services with hubs, Farm, and its settings.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
#if canImport(VaultUI)
import VaultUI
#endif

/// This device's own pages
struct DevicePageView: View {
  let page: DevicePage
  var body: some View {
    switch page {
    case .localHub:
#if canImport(HubServer)
      NavigationStack { LocalHubView() }.kitPane(.content)
        .pageToolbar(String(localized: "Run a Hub"), meta: [String(localized: "on this \(KitDevice.nameInSentence)")], systemImage: "server.rack", hue: .gray) { }
#else
      EmptyState(systemImage: "server.rack", title: "Not on This Device")
#endif
    case .sharedServices:
      SharedServicesPage()
    case .farm:
#if !os(tvOS) && !os(visionOS)
      NavigationStack { FarmView() }.kitPane(.content)
        .pageToolbar(String(localized: "Farm"), meta: [Farm.main.isRunning ? String(localized: "Farming") : String(localized: "Off")], systemImage: "tree", hue: .green) { }
#else
      EmptyState(systemImage: "tree", title: "Not on This Device")
#endif
    case .settings:
      DeviceSettingsPage()
    }
  }
}

/// This device's keys, the iCloud switch every v57 app shares, and Reset Data
struct DeviceSettingsPage: View {
  @State private var hubs = Hubs.main
  @State private var isConfirming = false
  @State private var isResetting = false

  var body: some View {
    ScrollView {
      VStack(spacing: KitMetrics.gutter) {
#if canImport(VaultUI)
        VaultICloudCard()
#endif
        ForEach(hubs.list) { hub in
          HubKeysSection(hub: hub)
        }
        DevicePortsSection()
        KitSection("Shared Keys", meta: [String(localized: "kept by Reset Data")], systemImage: "key", hue: .gray) {
          VStack(spacing: 8) {
            Text("Hubs from before each hub got keys of its own stay on these, and so does the hub this \(KitDevice.nameInSentence) runs.")
              .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
            KeyValueLine(key: "Your Key", value: KeyChain.main.publicKey(), mono: true)
            KeyValueLine(key: "Device Key", value: DeviceIdentity.app?.key.publicKey ?? "–", mono: true)
          }.padding(8)
        }
        KitSection("Reset Data", meta: [String(localized: "everything but the keys")], systemImage: "trash", hue: .red) {
          Text("Removes your hubs, settings and caches, Hub Network membership and its VPN profile, and the hub this \(KitDevice.nameInSentence) runs with its data. Your keys stay, so hubs that know this \(KitDevice.nameInSentence) still recognize it.")
            .kitFont(.caption).fixedSize(horizontal: false, vertical: true).padding(8)
        } accessory: {
          Button(isResetting ? "Resetting…" : "Reset Data", role: .destructive) { isConfirming = true }
            .buttonStyle(.kit).controlSize(.small).disabled(isResetting)
        }
      }
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
    }
    .kitPane(.content)
    .pageToolbar(String(localized: "Settings"), meta: [String(localized: "this \(KitDevice.nameInSentence)")], systemImage: "gearshape", hue: .gray) { }
#if DEBUG
    // For checks that Reset Data kept them: compare with its `[HubReset] KEPT` lines after a relaunch
    .onAppear { print("[HubSettings] keys \(KeyChain.main.publicKey()) \(DeviceIdentity.app?.key.publicKey ?? "-")") }
#endif
    .kitDialog(
      "Reset Data?", isPresented: $isConfirming,
      message: "Hub forgets every hub, its settings, Hub Network and the hub this \(KitDevice.nameInSentence) runs, and starts over. Your keys stay. This can't be undone.",
      systemImage: "trash", hue: .red, confirm: "Reset Data", role: .destructive
    ) {
      Task { await reset() }
    }
  }

  /// Ends at the welcome
  private func reset() async {
    isResetting = true
    _ = await HubReset.resetData()
    isResetting = false
  }
}

/// What another device may open here over Hub Network: a Hub can narrow this, never widen it
private struct DevicePortsSection: View {
  @State private var isSSHEnabled = DevicePorts.main.isSSHEnabled
  @State private var allowed = DevicePorts.main.allowed
  @State private var newPort = ""

  var body: some View {
    KitSection("Open Ports", meta: [String(localized: "besides what you share")], systemImage: "lock.open", hue: .orange) {
      VStack(spacing: 8) {
        Text("A hub can only open a port on this \(KitDevice.nameInSentence) that's shared from it or listed here, whatever the hub signs.")
          .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
#if os(macOS)
        Toggle("SSH (port \(DevicePorts.main.sshPort))", isOn: $isSSHEnabled)
          .onChange(of: isSSHEnabled) { _, enabled in DevicePorts.main.setSSH(enabled) }
#endif
        ForEach(allowed, id: \.self) { port in
          HStack {
            Text(port.title).frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove", systemImage: "xmark") {
              DevicePorts.main.remove(port)
              allowed = DevicePorts.main.allowed
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
          }
        }
        HStack {
          TextField("tcp/8080", text: $newPort).kitField(mono: true, content: .verbatim)
          Button("Allow") {
            guard let port = DevicePorts.Port(newPort) else { return }
            DevicePorts.main.allow(port)
            allowed = DevicePorts.main.allowed
            newPort = ""
          }
          .buttonStyle(.kit).controlSize(.small).disabled(DevicePorts.Port(newPort) == nil)
        }
      }.padding(8)
    }
  }
}

/// This device on one hub: the keys that hub knows it by, and the safety code an owner compares
private struct HubKeysSection: View {
  let hub: Hub
  @State private var request: DeviceRequest?

  var body: some View {
    KitSection(hub.settings.name, meta: [hub.usesSharedKeys ? String(localized: "shared keys") : String(localized: "keys of its own")], systemImage: "key", hue: .blue) {
      VStack(spacing: 8) {
        KeyValueLine(key: "Your Key", value: hub.key, mono: true)
        KeyValueLine(key: "Device Key", value: deviceKey ?? "–", mono: true)
        KeyValueLine(key: "Safety Code", value: safetyCode ?? "–")
        if let waiting {
          Text(waiting).kitFont(.caption).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }.padding(8)
    }
    .task(id: hub.isConnected) {
      // The value the code covers comes from the hub, on its own stream: older hubs have none, and show no code
      guard hub.isConnected, hub.client.device != nil, !hub.isDemo else { return }
      do {
        for try await request in hub.client.devices.request() {
          self.request = request
        }
      } catch {
        request = nil
      }
    }
  }

  private var deviceKey: String? { hub.client.device?.key.publicKey }

  private var safetyCode: String? {
    guard let deviceKey else { return nil }
    return hub.safetyCode(deviceKey: deviceKey, codeValue: request?.codeValue)
  }

  private var waiting: String? {
    switch request?.status {
    case .waiting: String(localized: "Waiting for its turn with this hub. The code comes once the hub has this \(KitDevice.nameInSentence)’s request.")
    case .pending: String(localized: "An owner compares this code and approves this \(KitDevice.nameInSentence).")
    case .approved: nil
    case nil: hub.isConnected ? String(localized: "This hub gives no safety code to compare.") : nil
    }
  }
}

/// The services this device can run for hubs: each one's switch per hub, and a page to try it here
struct SharedServicesPage: View {
  @State private var hubs = Hubs.main
#if DEBUG
  @State private var trying = ScreenshotPage.current?.service
#else
  @State private var trying: AppServices.Service?
#endif
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let connected = hubs.list.filter(\.isConnected)
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 280 : 320), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
        ForEach(AppServices.Service.allCases, id: \.self) { service in
          KitSection(Text(service.title)) {
            ForEach(connected) { hub in
              if let isOn = service.isEnabled(hub: hub) {
                SidebarRow("Share with \(hub.settings.name)") {
                  HubTile(hub: hub, size: 18)
                } trailing: {
                  Toggle("Share with \(hub.settings.name)", isOn: Binding { isOn } set: { service.set(enabled: $0, hub: hub) })
                    .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
                }
              }
            }
            if connected.isEmpty {
              Text("Connect to a hub to share it.").kitFont(.caption).padding(8)
            }
          } icon: {
            Tile(systemImage: service.image, hue: .purple, size: idiom == .mac ? 24 : 28)
          } meta: {
            Text(service.description).lineLimit(2)
          } accessory: {
            Button("Try It") { trying = service }.buttonStyle(.kit).controlSize(.small)
          }
        }
      }
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
    }
    .kitPane(.content)
    .pageToolbar(String(localized: "Shared Services"), meta: [String(localized: "what this \(KitDevice.nameInSentence) runs for its hubs"), String(localized: "\(AppServices.Service.sharedCount) shared")], systemImage: "square.and.arrow.up", hue: .purple) { }
    .navigationDestination(item: idiom == .phone ? $trying : .constant(nil)) { service in
      AppServices.Page(service: service)
        .kitPane(.content)
        .pageToolbar(service.name, meta: [String(localized: "on this \(KitDevice.nameInSentence)")], systemImage: service.image, hue: .purple) { }
    }
    .kitSheet(item: idiom == .phone ? .constant(nil) : $trying) { service in
      KitSheet(title: service.name, meta: String(localized: "On this \(KitDevice.nameInSentence)"), systemImage: service.image, hue: .purple, width: 720) {
        AppServices.Page(service: service).frame(minHeight: 460)
      } footer: {
        Button("Done") { trying = nil }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      }
    }
  }
}

extension AppServices.Service: Identifiable {
  var name: String {
    switch self {
    case .imageEncoder: String(localized: "Image encoder")
    case .videoEncoder: String(localized: "Video encoder")
    case .sensitiveContent: String(localized: "Detect sensitive content")
    case .translate: "Apple Intelligence Translate"
    case .chat: "Apple Intelligence Chat"
    }
  }
  /// Services shared with at least one hub
  @MainActor static var sharedCount: Int {
    allCases.filter { service in Hubs.main.list.contains { service.isEnabled(hub: $0) == true } }.count
  }
}
#endif
