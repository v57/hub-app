//
//  HubPages.swift
//  Hub
//
//  The page the sidebar opens for a hub, under the kit's toolbar: the page's name, its hub and its counts.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

struct HubPageView: View {
  let page: HubPage
  @Environment(Hub.self) private var hub

  var body: some View {
    Group {
      switch page {
      case .overview: OverviewPage()
      case .services: ServicesPage()
      case .apps: AppsPage()
      case .files: FilesPage()
      case .cameras: CamerasPage()
      case .launcher: LauncherPage()
      case .devices: DevicesPage()
      case .requests: RequestsPage()
      case .connections: ConnectionsPage()
      case .permissions: PermissionsPage()
      case .lockdown: LockdownPage()
      case .network: NetworkPage()
      }
    }
    .overlay {
      if hub.reach != .online {
        HubUnreachable()
      }
    }
  }
}

/// Any page of a hub that isn't connected: what keeps it away, with the hub's own actions
struct HubUnreachable: View {
  @Environment(Hub.self) private var hub
  @Environment(ShellModel.self) private var shell

  var body: some View {
    Group {
      switch hub.reach {
      case .connecting:
        EmptyState(systemImage: "hexagon", title: "Connecting to \(hub.settings.name)…", message: "\(hub.settings.address.absoluteString)", status: .working)
      case .refused where hub.refusal == .hubNeedsUpdate:
        // A Hub from before auth v2 can't prove its key, so it gets nothing from this device until it's updated
        EmptyState(
          systemImage: "arrow.down.circle", title: "\(hub.settings.name) Needs an Update",
          message: HubClient.hubNeedsUpdateText
        ) {
          Button("Copy Update Command") { KitPasteboard.copy("hub update") }.buttonStyle(.kit)
          Button("Remove…") { shell.removing = hub }.buttonStyle(.kit)
        }
      case .refused:
        EmptyState(
          systemImage: "exclamationmark.shield", title: "\(hub.settings.name) Refused This \(KitDevice.name)",
          message: hub.refusal.map { "\($0.description)" }
        ) {
          if case .hubKeyChanged = hub.refusal {
            Button("Trust New Hub Key") {
              Hubs.main.trustNewKey(of: hub)
            }
            .buttonStyle(.kit)
          }
          Button("Remove…") { shell.removing = hub }.buttonStyle(.kit)
        }
      case .offline, .online:
        EmptyState(
          systemImage: "arrow.clockwise", title: "\(hub.settings.name) Isn’t Reachable",
          message: "Hub keeps trying \(hub.settings.address.absoluteString). Its pages show what they last loaded."
        ) {
          Button("Copy Address") { KitPasteboard.copy(hub.settings.address.absoluteString) }.buttonStyle(.kit)
          Button("Remove…") { shell.removing = hub }.buttonStyle(.kit)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.kitWindow)
  }
}

/// A page's toolbar title parts: the hub's name, then the page's counts
@MainActor
struct PageMeta {
  static func parts(_ hub: Hub, _ parts: [String]) -> [String] {
    [hub.settings.name] + parts
  }
}

// MARK: - Pages not redesigned yet: today's views under the kit's toolbar

struct AppsPage: View {
  @Environment(Hub.self) private var hub
  var facts = HubFacts()
  @State private var homeApps = HomeApps.main

  var body: some View {
    let apps = facts.apps
    let hidden = apps.filter { homeApps.isHidden($0, in: hub.id) }
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        if apps.isEmpty {
          EmptyState(
            systemImage: "square.grid.3x3", title: "No Apps on \(hub.settings.name)",
            message: "Services publish apps: pages, widgets and web apps drawn from what they describe."
          )
          .padding(.top, 80)
        } else {
          AppsCard(apps: apps.filter { !homeApps.isHidden($0, in: hub.id) })
          if !hidden.isEmpty {
            KitSection("Hidden", meta: [String(localized: "not on All Hubs or Overview")], systemImage: "eye.slash", hue: .gray) {
              ForEach(hidden) { app in
                SidebarRow(app.name) {
                  AppTileIcon(app: app, size: 20)
                } trailing: {
                  Button("Show") { withAnimation(.kit) { homeApps.setHidden(false, app, in: hub.id) } }
                    .buttonStyle(.kit).controlSize(.small)
                }
              }
            }
          }
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane(.content)
    .pageToolbar(String(localized: "Apps"), meta: PageMeta.parts(hub, [apps.count == 1 ? String(localized: "1 app") : String(localized: "\(apps.count) apps")]), systemImage: HubPage.apps.systemImage, hue: .purple) { }
  }
}

struct NetworkPage: View {
  var body: some View {
    HubNetworkPage()
  }
}

/// A service app, drawn by HubUI from the description its service sends
struct ServiceAppPage: View {
  let path: String
  @Environment(Hub.self) private var hub
  @HubState(\.statusBadges) private var badges

  var body: some View {
    if let app = badges.apps?.first(where: { $0.path == path }) {
      Group {
        if app.web != nil {
#if canImport(WebKit)
          HubWebAppView(header: app)
#else
          EmptyState(systemImage: "globe", title: "A Web App", message: "\(app.name) opens in a browser on your other devices.")
#endif
        } else {
          HubAppView(header: app)
        }
      }
      .hubCardStyle { $0.kitSurface(.card) }
      .kitPane(.content)
      .pageToolbar(app.name, meta: PageMeta.parts(hub, [app.isOnline ? "" : String(localized: "Offline")]), systemImage: app.icon ?? "app", hue: StableHue.pick(app.name)) { }
    } else {
      EmptyState(systemImage: "app.dashed", title: "Loading the App…", status: .working)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .kitPane(.content)
    }
  }
}

#endif

#if canImport(ComponentKit)
/// iPhone: a hub's pages in the sidebar's three cards; a page pushes
struct HubPagesList: View {
  @Environment(Hub.self) private var hub
  var facts = HubFacts()
  @State private var pushed: HubPage?
  @State private var showsMenu = false

  var body: some View {
    ScrollView {
      VStack(spacing: KitMetrics.gutter) {
        HubPagesCards(hub: hub) { pushed = $0 }
      }
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
    }
    .kitPane(.content)
    .pageToolbar(hub.settings.name, title: {
      RichHeader(Text(hub.settings.name), size: .title) {
        HubTile(hub: hub, size: 28)
      } meta: {
        MetaLine([facts.summary])
      } accessory: {
        EmptyView()
      }
    }) {
      Button("More", systemImage: "ellipsis") { showsMenu = true }
        .buttonStyle(.kitRound)
        .kitMenu(isPresented: $showsMenu) { HubMenu(hub: hub) }
    }
    .navigationDestination(item: $pushed) { page in
      HubPageView(page: page).hub(hub)
    }
  }
}
#endif
