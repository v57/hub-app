//
//  DevicePages.swift
//  Hub
//
//  What this device does on its own: run a hub, share its services with hubs, Farm.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

/// This device's own pages
struct DevicePageView: View {
  let page: DevicePage
  var body: some View {
    switch page {
    case .localHub:
#if canImport(HubServer)
      NavigationStack { LocalHubView() }.kitPane(.content)
        .pageToolbar("Run a Hub", meta: ["on this \(KitDevice.name)"], systemImage: "server.rack", hue: .gray) { }
#else
      EmptyState(systemImage: "server.rack", title: "Not on This Device")
#endif
    case .sharedServices:
      SharedServicesPage()
    case .farm:
#if os(macOS) || os(iOS)
      NavigationStack { FarmView() }.kitPane(.content)
        .pageToolbar("Farm", meta: [Farm.main.isRunning ? "Farming" : "Off"], systemImage: "tree", hue: .green) { }
#else
      EmptyState(systemImage: "tree", title: "Not on This Device")
#endif
    }
  }
}

/// The services this device can run for hubs: each one's switch per hub, and a page to try it here
struct SharedServicesPage: View {
  @State private var hubs = Hubs.main
  @State private var trying: AppServices.Service?
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
    .pageToolbar("Shared Services", meta: ["what this \(KitDevice.name) runs for its hubs", "\(AppServices.Service.sharedCount) shared"], systemImage: "square.and.arrow.up", hue: .purple) { }
    .navigationDestination(item: idiom == .phone ? $trying : .constant(nil)) { service in
      AppServices.Page(service: service)
        .kitPane(.content)
        .pageToolbar(service.name, meta: ["on this \(KitDevice.name)"], systemImage: service.image, hue: .purple) { }
    }
    .kitSheet(item: idiom == .phone ? .constant(nil) : $trying) { service in
      KitSheet(title: service.name, meta: "On this \(KitDevice.name)", systemImage: service.image, hue: .purple, width: 720) {
        AppServices.Page(service: service).frame(minHeight: 460)
      } footer: {
        Spacer()
        Button("Done") { trying = nil }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      }
    }
  }
}

extension AppServices.Service: Identifiable {
  var name: String {
    switch self {
    case .imageEncoder: "Image encoder"
    case .videoEncoder: "Video encoder"
    case .sensitiveContent: "Detect sensitive content"
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
