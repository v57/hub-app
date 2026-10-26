//
//  TVRootView.swift
//  Hub
//
//  Hub on Apple TV: the title and a tab for All Hubs, each hub and Search across the top; All Hubs shows each hub's
//  most used pages and apps as tiles, and a hub's tab has its own tabs for its pages. Focus tilts and lights the
//  focused tile and lifts its hub (the kit's focus effect, no ring).
//

#if os(tvOS) && canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

/// The tabs across the top
enum TVTab: Hashable {
  case allHubs
  case hub(Hub.ID)
  case search
}

struct TVRootView: View {
  @State private var hubs = Hubs.main
  @State private var navigator = Navigator.main
  @State private var tab = TVTab.allHubs
  @State private var shell = ShellModel()

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 40) {
          Group {
            if case .hub(let id) = tab, let hub = hubs.list.first(where: { $0.id == id }) {
              HStack(spacing: 20) {
                HubTile(hub: hub, size: 64)
                Text(hub.settings.name)
              }
            } else {
              Text("Hub")
            }
          }
          .kitFont(.title1)
          .frame(minWidth: 280, alignment: .leading)
          KitSegmented(selection: $tab, segments: tabs)
          Spacer(minLength: 0)
        }
        switch tab {
        case .allHubs where hubs.list.isEmpty:
          HubWelcome()
        case .allHubs:
          TVAllHubs { hub, page in open(hub, page) }
        case .hub(let id):
          if let hub = hubs.list.first(where: { $0.id == id }) {
            TVHubTab(page: tabPage(for: hub)).hub(hub).id(hub.id)
          }
        case .search:
          TVSearch { hub, page in open(hub, page) }
        }
      }
      .padding(.horizontal, 80)
      .padding(.top, 40)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .navigationDestination(for: TVAppLink.self) { link in
        if let hub = hubs.list.first(where: { $0.id == link.hub }) {
          ServiceAppPage(path: link.path).hub(hub)
        }
      }
    }
    .environment(shell)
    .kitSheet(item: $shell.sheet) { sheet in
      switch sheet {
      case .connect: ConnectSheet()
      case .browseOwnInternet, .internetSetup: EmptyView()
      }
    }
#if DEBUG
    // `--open Home/devices`: that hub's tab on that page, for captures
    .onAppear {
      guard CommandLine.arguments.contains("--open"), case .hub(let id, let page) = navigator.route,
            let hub = hubs.list.first(where: { $0.id == id }) else { return }
      open(hub, page)
    }
#endif
  }

  /// All Hubs, the hubs that answer (five at most, then Search finds the rest), Search
  private var tabs: [KitSegment<TVTab>] {
    let shown = navigator.sorted(hubs.list).filter { !$0.reach.isHidden }.prefix(5)
    return [KitSegment("All Hubs", value: .allHubs)]
      + shown.map { KitSegment($0.settings.name, value: .hub($0.id)) }
      + [KitSegment("Search", value: .search, systemImage: "magnifyingglass")]
  }

  @State private var pages: [Hub.ID: HubPage] = [:]
  private func tabPage(for hub: Hub) -> Binding<HubPage> {
    Binding { pages[hub.id] ?? .overview } set: { pages[hub.id] = $0 }
  }

  private func open(_ hub: Hub, _ page: HubPage) {
    pages[hub.id] = page
    tab = .hub(hub.id)
  }
}

/// A service app to push from a tile
struct TVAppLink: Hashable {
  let hub: Hub.ID
  let path: String
}

// MARK: - All Hubs

private struct TVAllHubs: View {
  let open: (Hub, HubPage) -> Void
  @State private var hubs = Hubs.main
  @State private var navigator = Navigator.main

  var body: some View {
    let listed = navigator.sorted(hubs.list).filter { !$0.reach.isHidden }
    VStack(alignment: .leading, spacing: 32) {
      Text(MetaLine.join([
        listed.count == 1 ? "1 hub" : "\(hubs.list.count) hubs", "\(hubs.list.filter(\.isConnected).count) online",
      ]))
      .kitFont(.caption)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 3), spacing: 48) {
          ForEach(listed) { hub in
            TVHubSection(open: open).hub(hub)
          }
        }
        .padding(.vertical, 24)
      }
      .scrollClipDisabled()
    }
  }
}

/// A hub on All Hubs: its header, then its most used pages and apps as tiles (three and More)
private struct TVHubSection: View {
  let open: (Hub, HubPage) -> Void
  @Environment(Hub.self) private var hub
  var facts = HubFacts()
  @FocusState private var focused: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      RichHeader(Text(hub.settings.name)) {
        HubTile(hub: hub, size: 56)
      } meta: {
        MetaLine([facts.summary])
      } accessory: {
        if facts.requests > 0 {
          Chip(facts.requests == 1 ? "1 request" : "\(facts.requests) requests", hue: .orange)
        }
      }
      if hub.reach == .online {
        HStack(alignment: .top, spacing: 8) {
          ForEach(items.prefix(3)) { item in
            tile(item)
          }
          if items.count > 3 {
            Button { open(hub, .overview) } label: {
              Label {
                Text("More")
              } icon: {
                Text("+\(items.count - 3)").kitFont(.headline).foregroundStyle(.kitSecondary)
                  .frame(width: 88, height: 88)
                  .background(.kitFill, in: .rect(cornerRadius: 20))
              }
            }
            .focused($focused, equals: "more")
          }
        }
        .labelStyle(TVTileLabelStyle())
        .buttonStyle(.kitHoverEffect)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The hub with the focus lifts as a card
    .background {
      if focused != nil {
        RoundedRectangle(cornerRadius: 32).fill(.kitCard).shadow(color: .black.opacity(0.12), radius: 30, y: 12)
      }
    }
    .scaleEffect(focused != nil ? 1.03 : 1)
    .animation(.kit, value: focused)
    .focusSection()
  }

  private var items: [HubTileItem] {
    let pages = HubPage.tilePages.filter { page in hub.canOpen(page) && (page != .requests || facts.requests > 0) }
      .map(HubTileItem.page)
    let apps = facts.apps.filter { $0.isOnline }.map(HubTileItem.app)
    // Requests first when something waits, then the apps, then the pages
    let waiting = pages.filter { if case .page(let page) = $0 { page == .requests || (page == .devices && !facts.pendingDevices.isEmpty) } else { false } }
    let rest = pages.filter { item in !waiting.contains { $0.id == item.id } }
    return waiting + apps + rest
  }

  @ViewBuilder
  private func tile(_ item: HubTileItem) -> some View {
    switch item {
    case .page(let page):
      Button { open(hub, page) } label: {
        Label {
          Text(page.title)
        } icon: {
          Tile(systemImage: page.systemImage, hue: page.hue, size: 88)
            .overlay(alignment: .topTrailing) { badge(page) }
        }
      }
      .focused($focused, equals: item.id)
    case .app(let app):
      NavigationLink(value: TVAppLink(hub: hub.id, path: app.path)) {
        Label {
          Text(app.name)
        } icon: {
          AppTileIcon(app: app, size: 88)
        }
      }
      .focused($focused, equals: item.id)
    }
  }

  @ViewBuilder
  private func badge(_ page: HubPage) -> some View {
    let count = page == .devices ? facts.pendingDevices.count : page == .requests ? facts.badges.security ?? 0 : 0
    if count > 0 {
      Text("\(count)").kitFont(.caption).fontWeight(.semibold).foregroundStyle(.white)
        .padding(.horizontal, 10).frame(minWidth: 32, minHeight: 32)
        .background(Hue.red.fill, in: .capsule)
        .offset(x: 10, y: -10)
    }
  }
}

/// A tile and its name under it; the tile tilts and lights while focused, the name stays outside the effect
private struct TVTileLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(spacing: 12) {
      configuration.icon
        .kitHoverEffect(in: .rect(cornerRadius: 20))
      configuration.title
        .kitFont(.caption)
        .lineLimit(1)
        .foregroundStyle(.kitLabel)
    }
    .frame(width: 120)
  }
}

// MARK: - A hub

/// A hub's tab: its pages as tabs, each page without its title bar
private struct TVHubTab: View {
  @Binding var page: HubPage
  @Environment(Hub.self) private var hub

  /// The tabs a TV shows; Access opens Connections, where the hub's keys and groups are
  private var tabs: [(String, HubPage)] {
    [("Overview", .overview), ("Services", .services), ("Apps", .apps), ("Devices", .devices), ("Access", .connections), ("Network", .network)]
      .filter { hub.canOpen($0.1) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      KitSegmented(selection: $page, options: tabs)
      Group {
        if hub.reach == .online {
          HubPageView(page: page)
        } else {
          HubUnreachable()
        }
      }
      .environment(\.hidesPageToolbar, true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// MARK: - Search

/// Hubs, pages and apps by name
private struct TVSearch: View {
  let open: (Hub, HubPage) -> Void
  @State private var text = ""
  @State private var hubs = Hubs.main

  var body: some View {
    VStack(alignment: .leading, spacing: 32) {
      TextField("Hubs, apps, devices", text: $text)
        .frame(maxWidth: 900)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(hubs.list.filter { !text.isEmpty && $0.settings.name.localizedCaseInsensitiveContains(text) }) { hub in
            Button { open(hub, .overview) } label: {
              HStack(spacing: 20) {
                HubTile(hub: hub, size: 56)
                Text(hub.settings.name)
              }
              .padding(16)
              .frame(maxWidth: 900, alignment: .leading)
              .background(.kitCard, in: .rect(cornerRadius: 24))
              .kitHoverEffect(in: .rect(cornerRadius: 24))
            }
            .buttonStyle(.kitHoverEffect)
          }
        }
      }
    }
  }
}
#endif
