//
//  Sidebar.swift
//  Hub
//
//  The fast way to every feature: hubs on top (sorted, the unreachable ones behind Show More), the open hub's pages in
//  three cards that wait at the bottom however long the list gets, then what this device offers.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct HubSidebar: View {
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @State private var navigator = Navigator.main
  @State private var hubs = Hubs.main
  @State private var search = ""
  @State private var copied = false
  @Environment(\.kitIdiom) private var idiom
  @Environment(ShellModel.self) private var shell

  var body: some View {
    KitSidebar(
      selection: $navigator.route, searchText: $search, searchPrompt: "Search Hubs",
      columnVisibility: idiom.isTouch ? $columnVisibility : nil
    ) {
      if idiom != .pad || navigator.openHub == nil || !search.isEmpty {
        HubsSection(search: search)
          .kitSticky()
      }
      if let hub = navigator.openHub, search.isEmpty, idiom != .phone {
        OpenHubSections(hub: hub, page: navigator.route?.hubPage).hub(hub)
      }
      if search.isEmpty {
        ThisDeviceSection()
      }
    } bottomBar: {
      Button(copied ? "Copied" : "Copy My Key", systemImage: copied ? "checkmark" : "key") { copyKey() }
      Button("Connect to a Hub", systemImage: "plus") { shell.sheet = .connect }
    }
    .status {
      let online = hubs.list.filter(\.isConnected).count
      HStack(spacing: 6) {
        StatusDot(hue: online > 0 ? .green : .gray)
        Text("\(online) of \(hubs.list.count) online")
      }
    }
    .navigationTitle("Hub")
  }

  private func copyKey() {
    KeyChain.main.publicKey().copyToClipboard()
    withAnimation(.kit) { copied = true }
    Task {
      try? await Task.sleep(for: .seconds(2))
      withAnimation(.kit) { copied = false }
    }
  }
}

// MARK: - Hubs

/// Every hub this app knows, with All Hubs on top: the reachable ones in the chosen order, the rest behind Show More.
private struct HubsSection: View {
  let search: String
  @State private var navigator = Navigator.main
  @State private var hubs = Hubs.main
  @State private var showsAll = false
  @State private var showsSort = false
  @Environment(ShellModel.self) private var shell

  var body: some View {
    let sorted = navigator.sorted(hubs.list).filter {
      search.isEmpty || $0.settings.name.localizedCaseInsensitiveContains(search)
    }
    let shown = sorted.filter { !$0.reach.isHidden || showsAll || !search.isEmpty }
    let hidden = sorted.count - sorted.filter { !$0.reach.isHidden }.count
    KitSection(
      "Hubs", meta: ["\(shown.count) of \(hubs.list.count)", navigator.sort.title], systemImage: "hexagon"
    ) {
      SidebarRow(value: Route.allHubs, "All Hubs") {
        Tile(systemImage: "square.grid.2x2.fill", hue: .accent, style: .solid)
      } trailing: {
        AllHubsCount()
      }
      ForEach(shown) { hub in
        HubRow(hub: hub).hub(hub)
      }
      if hidden > 0 && search.isEmpty {
        SidebarRow(showsAll ? "Show Less" : "Show \(hidden) More") {
          Image(systemName: showsAll ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Hue.accent.text)
            .frame(width: 24)
        } trailing: {
          Text("offline or off").kitFont(.caption)
        }
        .title(Text(showsAll ? "Show Less" : "Show \(hidden) More").foregroundStyle(Hue.accent.text))
        .action { withAnimation(.kit) { showsAll.toggle() } }
      }
    } accessory: {
      Button("Sort Hubs", systemImage: "arrow.up.arrow.down") { showsSort = true }
        .kitMenu(isPresented: $showsSort) {
          KitMenuOptions(selection: $navigator.sort, options: HubSort.allCases.map { ($0.title, $0) })
          Divider()
          Button(showsAll ? "Hide Offline Hubs" : "Show Offline Hubs") {
            withAnimation(.kit) { showsAll.toggle() }
          }
        }
      Button("Connect to a Hub", systemImage: "plus") { shell.sheet = .connect }
    }
  }
}

/// What all hubs need from you
private struct AllHubsCount: View {
  @State private var hubs = Hubs.main
  var body: some View {
    // Each hub's count is read in its own row; this sums the badges the rows already subscribe to
    let total = hubs.list.reduce(0) { total, hub in
      total + (hub.state.statusBadges.value.security ?? 0) + hub.state.pendingDevices.value.count
    }
    if total > 0 {
      Count(total, .attention)
    }
  }
}

private struct HubRow: View {
  let hub: Hub
  var facts = HubFacts()
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    // On iPhone a hub pushes the list of its pages
    SidebarRow(value: Route.hubHome(hub.id), hub.settings.name, subtitle: facts.summary) {
      HubTile(hub: hub)
    } trailing: {
      if facts.requests > 0 {
        Count(facts.requests, .attention)
      } else {
        StatusDot(hue: hub.reach.hue, isHollow: hub.reach == .offline)
      }
    }
    .isCurrent(Navigator.main.route?.hubID == hub.id)
    .kitContextMenu { HubMenu(hub: hub) }
  }
}

/// A hub's own actions: the sidebar card's "…", a row's context menu and an All Hubs card's menu
struct HubMenu: View {
  let hub: Hub
  @Environment(ShellModel.self) private var shell

  var body: some View {
    Button("Open", systemImage: "arrow.right.circle") { Navigator.main.open(hub) }
    Button("Copy Address", systemImage: "doc.on.doc") { hub.settings.address.absoluteString.copyToClipboard() }
    if case .hubKeyChanged = hub.refusal {
      // Only when the hub was really reinstalled: otherwise another server answers at this address
      Button("Trust New Hub Key", systemImage: "checkmark.shield") {
        hub.refusal = nil
        hub.client.forgetHubKey()
      }
    }
    Divider()
    Button("Remove…", systemImage: "trash", role: .destructive) { shell.removing = hub }
  }
}

/// iPad's hub switcher: All Hubs, the reachable hubs in the sidebar's order, the rest in a submenu
private struct HubSwitcherMenu: View {
  @State private var navigator = Navigator.main
  @State private var hubs = Hubs.main

  var body: some View {
    let sorted = navigator.sorted(hubs.list)
    let hidden = sorted.filter(\.reach.isHidden)
    Button("All Hubs", systemImage: "square.grid.2x2") { navigator.route = .allHubs }
    Divider()
    ForEach(sorted.filter { !$0.reach.isHidden }) { hub in
      Toggle(isOn: Binding { navigator.route?.hubID == hub.id } set: { _ in navigator.open(hub) }) {
        Label { Text(hub.settings.name) } icon: { HubTile(hub: hub, size: 22) }
      }
    }
    if !hidden.isEmpty {
      KitSubmenu("Show \(hidden.count) More", systemImage: "ellipsis") {
        ForEach(hidden) { hub in
          Button(hub.settings.name) { navigator.open(hub) }
        }
      }
    }
  }
}

// MARK: - The open hub

/// The open hub's pages in three cards. The card with the open page waits at the bottom whole while it's below the
/// visible area, the others by their titles.
struct OpenHubSections: View {
  let hub: Hub
  let page: HubPage?
  var facts = HubFacts()
  @State private var showsMenu = false
  @Environment(\.kitIdiom) private var idiom
  @HubState(\.whitelist) private var whitelist

  var body: some View {
    let pages = HubPage.allCases.filter { hub.canOpen($0) }
    KitSection(Text(hub.settings.name)) {
      ForEach(pages.filter { $0.group == .hub }, id: \.self) { page in
        HubPageRow(hub: hub, page: page)
      }
    } icon: {
      HubTile(hub: hub, size: idiom == .mac ? 24 : 28)
    } meta: {
      MetaLine(facts.summary)
    } accessory: {
      if idiom == .pad {
        // iPad: the open hub's header switches hubs
        if facts.requests > 0 { Count(facts.requests, .attention) }
        Button("Switch Hub", systemImage: "chevron.up.chevron.down") { showsMenu = true }
          .kitMenu(isPresented: $showsMenu) { HubSwitcherMenu() }
      } else {
        Button("More", systemImage: "ellipsis") { showsMenu = true }
          .kitMenu(isPresented: $showsMenu) { HubMenu(hub: hub) }
      }
    }
    .kitSticky(top: .none, bottom: sticky(.hub))
    let access = pages.filter { $0.group == .access }
    if !access.isEmpty {
      KitSection("Access", meta: AccessMeta.parts(facts: facts, hub: hub, lockdown: whitelist.enabled), systemImage: "shield", hue: .orange) {
        ForEach(access, id: \.self) { page in
          HubPageRow(hub: hub, page: page)
        }
      }
      .kitSticky(top: .none, bottom: sticky(.access))
    }
    if hub.canViewNetwork {
      NetworkSection(hub: hub)
        .kitSticky(top: .none, bottom: sticky(.network))
    }
  }

  private func sticky(_ group: HubPage.Group) -> KitStickyBottom {
    page?.group == group ? .content : .title
  }
}

/// iPhone: a hub's pages in the sidebar's cards, pushed instead of selected; the toolbar names the hub, so the first
/// card has no header
struct HubPagesCards: View {
  let hub: Hub
  let open: (HubPage) -> Void
  var facts = HubFacts()
  @HubState(\.whitelist) private var whitelist

  var body: some View {
    let pages = HubPage.allCases.filter { hub.canOpen($0) }
    VStack(spacing: 2) {
      ForEach(pages.filter { $0.group == .hub }, id: \.self) { page in
        HubPageRow(hub: hub, page: page, open: open)
      }
    }
    .padding(KitMetrics.cardPadding)
    .kitSurface(.card)
    let access = pages.filter { $0.group == .access }
    if !access.isEmpty {
      KitSection("Access", meta: AccessMeta.parts(facts: facts, hub: hub, lockdown: whitelist.enabled), systemImage: "shield", hue: .orange) {
        ForEach(access, id: \.self) { page in
          HubPageRow(hub: hub, page: page, open: open)
        }
      }
    }
    if hub.canViewNetwork {
      NetworkSection(hub: hub, open: open)
    }
  }
}

/// The Access card's line: who waits, requests, Lockdown
@MainActor
enum AccessMeta {
  static func parts(facts: HubFacts, hub: Hub, lockdown: Bool) -> [String] {
    var parts = [String]()
    let waiting = facts.pendingDevices.count
    if waiting > 0 { parts.append("\(waiting) waiting") }
    let requests = facts.badges.security ?? 0
    if requests > 0 { parts.append(requests == 1 ? "1 request" : "\(requests) requests") }
    if hub.canLockdown { parts.append(lockdown ? "Lockdown on" : "Lockdown off") }
    return parts
  }
}

/// A hub page's row, with what it counts at the end; it selects the page, or pushes it with `open`
struct HubPageRow: View {
  let hub: Hub
  let page: HubPage
  var open: ((HubPage) -> Void)?
  var facts = HubFacts()
  @HubState(\.status) private var status
  @HubState(\.launcherInfo) private var launcher
  @HubState(\.whitelist) private var whitelist
  @HubState(\.groups) private var groups
  @HubState(\.hostPending) private var hostPending

  var body: some View {
    if let open {
      SidebarRow(page.title) {
        RowTile(systemImage: page.systemImage)
      } trailing: {
        trailing
      }
      .action { open(page) }
    } else {
      SidebarRow(value: Route.hub(hub.id, page), page.title) {
        RowTile(systemImage: page.systemImage)
      } trailing: {
        trailing
      }
    }
  }

  @ViewBuilder
  private var trailing: some View {
    switch page {
    case .services:
      if facts.services > 0 { Count(status.services.count) }
    case .apps:
      if !facts.apps.isEmpty { Count(facts.apps.count) }
    case .launcher:
      let updates = launcher.apps.filter(\.updateAvailable).count
      if updates > 0 { Count(updates, .attention) }
    case .devices:
      if facts.pendingDevices.isEmpty {
        if !facts.devices.isEmpty { Count(facts.devices.filter(\.approved).count) }
      } else {
        Count(facts.pendingDevices.count, .attention)
      }
    case .requests:
      if !hostPending.list.isEmpty { Count(hostPending.list.count, .attention) }
    case .connections:
      if !facts.users.isEmpty { Count(facts.users.count) }
    case .permissions:
      if !groups.groups.isEmpty { Text(groups.groups.count == 1 ? "1 group" : "\(groups.groups.count) groups").kitFont(.caption) }
    case .lockdown:
      Text(whitelist.enabled ? "On" : "Off").kitFont(.caption)
    case .overview, .files, .network:
      EmptyView()
    }
  }
}

/// The hub's private network: whether this device joined, and the network's page
private struct NetworkSection: View {
  let hub: Hub
  var open: ((HubPage) -> Void)?
  @HubState(\.networkAgentStatus) private var agents
  @State private var nets = HubNets.main

  var body: some View {
    let online = agents.filter(\.available).count
    KitSection("Hub Network", systemImage: "globe", hue: .teal) {
      if let open {
        SidebarRow("Network") {
          RowTile(systemImage: "network")
        } trailing: {
          EmptyView()
        }
        .action { open(.network) }
      } else {
        SidebarRow(value: Route.hub(hub.id, .network), "Network") {
          RowTile(systemImage: "network")
        } trailing: {
          EmptyView()
        }
      }
    } meta: {
      HStack(spacing: 4) {
        if hub.net.isJoined {
          StatusDot(hue: .green, size: 6)
          Text("Joined")
        } else {
          Text("Not joined")
        }
        if !agents.isEmpty {
          Text("· \(online) of \(agents.count) online")
        }
      }
    }
  }
}

// MARK: - This device

/// What this device does on its own: run a hub, share its services, its key, Farm
private struct ThisDeviceSection: View {
#if os(macOS) || os(iOS)
  @State private var farm = Farm.main
  private var meta: [String] { [farm.isRunning ? "Farming" : "Farm off"] }
#else
  private var meta: [String] { [] }
#endif

  var body: some View {
    KitSection("This \(KitDevice.name)", meta: meta, systemImage: KitDevice.systemImage, hue: .gray) {
#if canImport(HubServer)
      SidebarRow(value: Route.device(.localHub), "Run a Hub", systemImage: "server.rack") {
        LocalHubTrailing()
      }
#endif
      SidebarRow(value: Route.device(.sharedServices), "Shared Services", systemImage: "square.and.arrow.up") {
        let shared = AppServices.Service.sharedCount
        if shared > 0 { Count(shared) }
      }
#if os(macOS) || os(iOS)
      SidebarRow(value: Route.device(.farm), "Farm", systemImage: "tree") {
        Text(farm.isRunning ? "On" : "Off").kitFont(.caption)
      }
#endif
    }
  }
}

#if canImport(HubServer)
private struct LocalHubTrailing: View {
  @State private var local = LocalHub.main
  var body: some View {
    Text(local.isRunning ? "On" : local.isEnabled ? "Starting" : "Off").kitFont(.caption)
  }
}
#endif

extension KitDevice {
  /// This device's symbol: a laptop, an iPad, an iPhone
  @MainActor static var systemImage: String {
    switch name {
    case "iPhone": "iphone"
    case "iPad": "ipad"
    default: "laptopcomputer"
    }
  }
}

extension Hub {
  /// Whether this app's key may open the page on this hub
  func canOpen(_ page: HubPage) -> Bool {
    switch page {
    case .overview: true
    case .services: true
    case .apps: true
    case .files: hasStorage || canInstall
    case .launcher: require(permissions: "launcher/status")
    case .devices: require(permissions: "hub/devices")
    case .requests: require(permissions: "hub/host/pending")
    case .connections: require(permissions: "hub/connections")
    case .permissions: require(permissions: "hub/group/list", "hub/group/names")
    case .lockdown: canLockdown
    case .network: canViewNetwork
    }
  }
}
#endif
