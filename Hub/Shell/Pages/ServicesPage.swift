//
//  ServicesPage.swift
//  Hub
//
//  The hub's APIs as a table grouped by their first path part, with the selected API's providers, load balancer and
//  requests in the inspector. On iPhone the groups are cards whose rows push the same details.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

/// One API path, or the group of paths that share a first part
struct APIRow: Identifiable, Hashable {
  var id: String
  var name: String
  var service: Status.Service?
  var needsApproval = false
  var children: [APIRow]?

  var isOnline: Bool { (service?.services ?? 0) > 0 }
  var statusWord: String {
    if needsApproval { return "Needs approval" }
    if isOnline { return "Online" }
    if (service?.disabled ?? 0) > 0 { return "Disabled" }
    return "Offline"
  }
  var statusHue: Hue {
    needsApproval ? .orange : isOnline ? .green : .gray
  }
}

enum APIFilter: String, CaseIterable, Hashable {
  case all, online, approval, offline
  var title: String {
    switch self {
    case .all: "All"
    case .online: "Online"
    case .approval: "Needs approval"
    case .offline: "Offline"
    }
  }
  func matches(_ row: APIRow) -> Bool {
    switch self {
    case .all: true
    case .online: row.isOnline
    case .approval: row.needsApproval
    case .offline: !row.isOnline && !row.needsApproval
    }
  }
}

struct ServicesPage: View {
  @Environment(Hub.self) private var hub
  @HubState(\.status) private var status
  @HubState(\.hostPending) private var pending
  @State private var filter = APIFilter.all
  @State private var search = ""
  @State private var selection: String?
  @State private var pushed: String?
  @State private var expanded: Set<String> = []
  @State private var didExpand = false
  @State private var sort: KitGridSort? = KitGridSort("Path")
  @State private var since = Date()
  @Environment(\.kitIdiom) private var idiom

  private var paths: [APIRow] {
    var rows = status.services.map { APIRow(id: $0.name, name: $0.name, service: $0) }
    let known = Set(rows.map(\.id))
    for item in pending.list {
      for path in item.pending where !known.contains(path) {
        rows.append(APIRow(id: path, name: path, needsApproval: true))
      }
    }
    return rows
  }

  private var groups: [APIRow] {
    let rows = paths.filter { filter.matches($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    let grouped = Dictionary(grouping: rows) { String($0.name.split(separator: "/").first ?? "") }
    return grouped.map { name, rows in
      APIRow(id: "group/\(name)", name: name, children: rows.sorted { $0.name < $1.name })
    }
    .sorted { $0.name < $1.name }
  }

  var body: some View {
    let groups = groups
    PageWithInspector(name: "services", showsInspector: selectedRow != nil) {
      VStack(spacing: KitMetrics.gutter) {
        HStack {
          KitSegmented(selection: $filter, segments: APIFilter.allCases.compactMap { filter in
            let count = paths.filter(filter.matches).count
            guard filter == .all || filter == .online || count > 0 else { return nil }
            return KitSegment(filter.title, value: filter, count: filter == .approval ? count : nil)
          })
          Spacer()
          if idiom != .phone {
            Text("\(status.requests.formatted()) requests since \(since.formatted(date: .omitted, time: .shortened))")
              .kitFont(.caption)
          }
        }
        if status.services.isEmpty && pending.list.isEmpty {
          if hub.api.isEmpty {
            LoadingCards()
            Spacer()
          } else {
            EmptyState(
              systemImage: "hexagon", title: "No Services on \(hub.settings.name)",
              message: "Services connect with their key and post their APIs here. Install one, or run your own."
            ) {
              if hub.canOpen(.launcher) {
                Button("Open Launcher") { Navigator.main.open(hub, .launcher) }.buttonStyle(.kitPrimary)
              }
            }
            .frame(maxHeight: .infinity)
          }
        } else if idiom == .phone {
          ScrollView {
            VStack(spacing: KitMetrics.gutter) {
              ForEach(groups) { group in
                KitSection(group.name, meta: [group.children?.count == 1 ? "1 API" : "\(group.children?.count ?? 0) APIs"], systemImage: "hexagon", hue: .blue) {
                  ForEach(group.children ?? []) { row in
                    SidebarRow(row.name, subtitle: "\(row.service?.requests ?? 0) requests") {
                      EmptyView()
                    } trailing: {
                      Chip(row.statusWord, hue: row.statusHue).controlSize(.small)
                    }
                    .title(Text(row.name).monospaced())
                    .action { pushed = row.id }
                  }
                }
              }
            }
            .padding(.bottom, 24)
          }
        } else {
          KitGrid(groups, columns: columns, selection: Binding {
            selection.map { [$0] } ?? []
          } set: { ids in
            guard let id = ids.first, !id.hasPrefix("group/") else { return }
            withAnimation(.kit) { selection = id }
          }, sort: $sort, children: \.children, expanded: $expanded) {
            EmptyView()
          }
        }
      }
      .padding(KitMetrics.gutter)
    } inspector: {
      if let row = selectedRow {
        APIInspector(row: row)
      }
    }
    .kitStatusBar {
      if idiom != .phone {
        HStack(spacing: 6) {
          StatusDot(hue: hub.isConnected ? .green : .gray)
          Text(MetaLine.join(["Connected to \(hub.settings.address.absoluteString)", "your key …\(hub.key.suffix(8))"]))
        }
      }
    }
    .kitToolbar("Services", meta: meta, systemImage: HubPage.services.systemImage, hue: .blue) {
      if idiom != .phone {
        KitSearchField(text: $search, prompt: "Path or provider").frame(width: 200)
      }
    }
    .onChange(of: groups.map(\.id), initial: true) { _, ids in
      // Every group starts open
      guard !didExpand, !ids.isEmpty else { return }
      expanded = Set(ids)
      didExpand = true
    }
    .navigationDestination(item: $pushed) { id in
      if let row = paths.first(where: { $0.id == id }) {
        ScrollView { APIInspector(row: row).padding(KitMetrics.gutter) }
          .kitPane(.content)
          .kitToolbar(row.name, meta: [row.statusWord], systemImage: "hexagon", hue: .blue) { }
          .hub(hub)
      }
    }
  }

  private var selectedRow: APIRow? {
    selection.flatMap { id in paths.first { $0.id == id } }
  }

  private var meta: [String] {
    let running = status.services.reduce(0) { $0 + ($1.running ?? 0) }
    let waiting = paths.filter(\.needsApproval).count
    return PageMeta.parts(hub, [
      paths.count == 1 ? "1 API" : "\(paths.count) APIs",
      running > 0 ? "\(running) running" : "",
      waiting > 0 ? "\(waiting) pending" : "",
    ])
  }

  private var columns: [KitGridColumn<APIRow>] {
    [
      KitGridColumn("Path", width: 240) { row in
        if row.children != nil {
          HStack(spacing: 6) {
            Text(row.name).fontWeight(.semibold)
            Text("\(row.children?.count ?? 0)").kitFont(.caption)
          }
        } else {
          Text(row.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
        }
      },
      KitGridColumn("Status", width: 120, content: { row in
        if row.children == nil {
          Chip(row.statusWord, hue: row.statusHue).controlSize(.small)
        }
      }),
      number("Providers") { $0.service?.services ?? 0 },
      number("Requests", width: 90) { $0.service?.requests ?? 0 },
      number("Running") { $0.service?.running ?? 0 },
      number("Pending") { $0.service?.pending ?? 0 },
      KitGridColumn("Load balancer", width: 150, content: { row in
        if row.children == nil {
          Text(row.service?.balancerType.title ?? "–").foregroundStyle(row.service == nil ? .kitTertiary : .kitLabel)
        }
      }),
    ]
  }
}

/// A number column that leaves the group rows blank
private func number(_ title: String, width: CGFloat = 80, _ value: @escaping (APIRow) -> Int) -> KitGridColumn<APIRow> {
  KitGridColumn(title, width: width, alignment: .trailing, content: { row in
    if row.children == nil {
      Text(value(row).formatted()).monospacedDigit()
    }
  })
}

/// An API: who provides it, how the hub picks a provider, and its requests
struct APIInspector: View {
  let row: APIRow
  @Environment(Hub.self) private var hub
  @State private var providers: [Provider] = []
  @State private var balancer: Status.BalancerType = .counter

  var body: some View {
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      RichHeader(Text(row.name).monospaced(), size: .title) {
        Tile(systemImage: "hexagon", hue: .blue, size: 28)
      } meta: {
        MetaLine([String(row.name.split(separator: "/").first ?? ""), row.service?.balancerType.title ?? "", (row.service?.running ?? 0) > 0 ? "\(row.service?.running ?? 0) running" : ""])
      } accessory: {
        EmptyView()
      }
      .titleAccessory { Chip(row.statusWord, hue: row.statusHue).controlSize(.small) }
      .padding(.horizontal, 4)
      KitSection("Providers", meta: ["\(row.service?.services ?? 0) online", "\(row.service?.disabled ?? 0) disabled"], systemImage: "server.rack", hue: .indigo) {
        if providers.isEmpty {
          Text(row.needsApproval ? "Waits for an owner to allow it" : "No provider is connected").kitFont(.caption).padding(8)
        }
        ForEach(providers) { provider in
          SidebarRow(provider.name ?? "Service", subtitle: "…" + provider.id.suffix(8)) {
            Tile(systemImage: "server.rack", hue: .gray, size: 18)
          } trailing: {
            EmptyView()
          }
        }
      }
      if let service = row.service {
        KitSection("Load balancer", meta: ["How requests pick a provider"], systemImage: "arrow.triangle.branch", hue: .red) {
          LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(Status.BalancerType.all, id: \.rawValue) { type in
              ChoiceCard(type.title, subtitle: type.subtitle, systemImage: type.icon, hue: .red, isOn: Binding {
                balancer == type
              } set: { isOn in
                guard isOn else { return }
                balancer = type
                Task { try? await hub.client.send("hub/balancer/set", BalancerUpdate(path: service.name, type: type.rawValue)) }
              })
            }
          }
          .padding(6)
          .disabled(!hub.require(permissions: "hub/balancer/set"))
        }
        KitSection("Requests", meta: ["Since the hub started"], systemImage: "chart.bar", hue: .green) {
          InspectorRow("Total", value: service.requests.formatted(), copyable: false)
          InspectorRow("Running", value: "\(service.running ?? 0)", copyable: false)
          InspectorRow("Pending", value: "\(service.pending ?? 0)", copyable: false)
        }
      }
      HStack {
        Button("Copy Path") { row.name.copyToClipboard() }.buttonStyle(.kit)
        if hub.canOpen(.permissions) {
          Button("Permissions…") { Navigator.main.open(hub, .permissions) }.buttonStyle(.kit)
        }
      }
      .controlSize(.small)
    }
    .task(id: row.id) {
      balancer = row.service?.balancerType ?? .counter
      providers = []
      guard !row.needsApproval, !hub.isDemo, hub.require(permissions: "hub/devices") else { return }
      do {
        for try await list in hub.client.devices.providers(row.name) {
          providers = list.map { Provider(id: $0.id, name: $0.name) }
        }
      } catch { }
    }
  }

  private struct Provider: Identifiable {
    let id: String
    let name: String?
  }
  private struct BalancerUpdate: Codable {
    let path: String
    let type: String
  }
}

extension Status.BalancerType {
  var title: String {
    switch self {
    case .random: "Random"
    case .counter: "Round-robin"
    case .first: "Queued"
    case .available: "Distributed"
    case .unknown: "Unknown"
    }
  }
  var subtitle: String {
    switch self {
    case .random: "Any provider"
    case .counter: "Each in turn"
    case .first: "In order"
    case .available: "First free provider"
    case .unknown: ""
    }
  }
}
#endif
