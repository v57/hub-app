//
//  DevicesPage.swift
//  Hub
//
//  The hub's devices: who wants to join first, then a card per device (or a table for large sets), the selected one
//  in the inspector.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct DevicesPage: View {
  @Environment(Hub.self) private var hub
  @HubState(\.devices) private var devices
  @HubState(\.pendingDevices) private var pending
  @AppStorage("devices.style") private var style = ListStyle.grid
  @State private var search = ""
  @State private var filter = DeviceFilter.all
  @State private var selection: String?
  @State private var pushed: String?
  @State private var sort: KitGridSort? = KitGridSort("Name")
  @Environment(\.kitIdiom) private var idiom

  private var approved: [Device] {
    devices.filter { $0.approved && !$0.revoked }
  }
  private var shown: [Device] {
    approved.filter { device in
      filter.matches(device) && (search.isEmpty || device.name.localizedCaseInsensitiveContains(search)
        || (device.platform ?? "").localizedCaseInsensitiveContains(search))
    }
    .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
  }

  var body: some View {
    PageWithInspector(name: "devices", showsInspector: selected != nil) {
      VStack(spacing: KitMetrics.gutter) {
        ForEach(pending.prefix(3)) { device in
          PendingDeviceBanner(device: device)
        }
        if style == .list || idiom == .phone {
          filters
        }
        if devices.isEmpty && hub.api.isEmpty {
          LoadingCards()
          Spacer()
        } else if approved.isEmpty {
          EmptyState(
            systemImage: "laptopcomputer", title: "No Devices Yet",
            message: "Devices join with an invite link or a pairing code from this \(KitDevice.name)."
          ) {
            if hub.canViewNetwork {
              Button("Invite…") { Navigator.main.open(hub, .network) }.buttonStyle(.kitPrimary)
            }
          }
          .frame(maxHeight: .infinity)
        } else if shown.isEmpty {
          EmptyState(systemImage: "magnifyingglass", title: "No Devices Match", message: "Nothing called “\(search)” among \(hub.settings.name)’s \(approved.count) devices.") {
            Button("Clear Search") { search = ""; filter = .all }.buttonStyle(.kit)
          }
          .frame(maxHeight: .infinity)
        } else if style == .grid || idiom == .phone {
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 150 : 232), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
              ForEach(shown) { device in
                DeviceCard(device: device, isSelected: selection == device.id) {
                  select(device.id)
                }
              }
            }
            .padding(.bottom, 24)
          }
        } else {
          DeviceTable(devices: shown, selection: $selection, sort: $sort)
        }
      }
      .padding(KitMetrics.gutter)
      .animation(.kit, value: pending.map(\.id))
    } inspector: {
      if let device = selected {
        DeviceInspector(device: device)
      }
    }
    .kitToolbar("Devices", meta: meta, systemImage: HubPage.devices.systemImage, hue: .blue) {
      if idiom != .phone {
        ListStyleSwitch(style: $style)
        KitSearchField(text: $search, prompt: "Name or kind").frame(width: 200)
      }
      if hub.canViewNetwork {
        ToolGroup {
          Button("Invite", systemImage: "person.badge.plus") { Navigator.main.open(hub, .network) }
        }
      }
    }
    .navigationDestination(item: $pushed) { id in
      if let device = devices.first(where: { $0.id == id }) {
        ScrollView { DeviceInspector(device: device).padding(KitMetrics.gutter) }
          .kitPane(.content)
          .kitToolbar(device.name, meta: [device.statusText], systemImage: Device.symbol(platform: device.platform), hue: .blue) { }
          .hub(hub)
      }
    }
  }

  private var selected: Device? {
    selection.flatMap { id in devices.first { $0.id == id } }
  }

  private func select(_ id: String) {
    if idiom == .phone {
      pushed = id
    } else {
      withAnimation(.kit) { selection = selection == id ? nil : id }
    }
  }

  private var meta: [String] {
    PageMeta.parts(hub, [
      approved.count == 1 ? "1 device" : "\(approved.count) devices",
      "\(approved.filter(\.online).count) online",
      pending.isEmpty ? "" : "\(pending.count) waiting",
    ])
  }

  private var filters: some View {
    HStack {
      KitSegmented(selection: $filter, segments: DeviceFilter.allCases.compactMap { filter in
        let count = approved.filter(filter.matches).count
        return filter == .all || count > 0 ? KitSegment(filter.title, value: filter, count: count) : nil
      })
      Spacer()
      if style == .list && idiom != .phone {
        Text("Sorted by \(sort?.column.lowercased() ?? "name")").kitFont(.caption)
      }
    }
  }
}

/// The list's filter: kinds of device, and the ones offline
enum DeviceFilter: String, CaseIterable, Hashable {
  case all, phones, computers, other, offline
  var title: String {
    switch self {
    case .all: "All"
    case .phones: "Phones"
    case .computers: "Computers"
    case .other: "Other"
    case .offline: "Offline"
    }
  }
  func matches(_ device: Device) -> Bool {
    switch self {
    case .all: true
    case .phones: ["ios", "ipados", "android"].contains(device.platform ?? "")
    case .computers: ["macos", "linux", "windows"].contains(device.platform ?? "")
    case .other: !["ios", "ipados", "android", "macos", "linux", "windows"].contains(device.platform ?? "")
    case .offline: !device.online
    }
  }
}

/// A device asking to join: its safety code to compare on the device, Deny and Approve
struct PendingDeviceBanner: View {
  let device: PendingDevice
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let name = device.name ?? "A device"
    Banner(
      "\(name) wants to join \(hub.settings.name)",
      message: MetaLine.join([
        device.platform.map(Device.systemName) ?? "",
        device.firstSeenDate.map { "asked \($0.formatted(.relative(presentation: .named)))" } ?? "",
        "check its safety code \(device.safetyCode) on the device",
      ]),
      systemImage: Device.symbol(platform: device.platform), hue: .orange
    ) {
      if hub.require(permissions: "hub/device/approve") {
        if idiom != .phone && hub.require(permissions: "hub/device/remove") {
          AsyncButton("Deny") { try await hub.client.devices.remove(device.id) }.buttonStyle(.kit)
        }
        AsyncButton(idiom == .phone ? "Approve" : "Approve…") { _ = try await hub.client.devices.approve(device.id) }
          .buttonStyle(.kitPrimary)
      }
    }
  }
}

/// A device's card: what it is and runs, its live load, its Hub Network address
struct DeviceCard: View {
  let device: Device
  var isSelected = false
  var action: () -> Void
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  @State private var data: DeviceData?

  var body: some View {
    GridCard(isSelected: isSelected, action: action) {
      VStack(alignment: .leading, spacing: 8) {
        RichHeader(Text(device.name)) {
          Tile(systemImage: Device.symbol(platform: device.platform), hue: device.online ? .blue : .gray, size: idiom == .phone ? 30 : 24)
        } meta: {
          MetaLine(device.cardLine(isThisDevice: device.key == hub.client.device?.key.publicKey, compact: idiom == .phone))
        } accessory: {
          HStack(spacing: 6) {
            if let battery = data?.battery {
              Label("\(Int(battery * 100))%", systemImage: data?.charging == true ? "battery.100.bolt" : "battery.75")
                .labelStyle(.titleAndIcon).kitFont(.caption)
            }
            StatusDot(hue: device.online ? .green : .gray, isHollow: !device.online)
          }
        }
        .padding(.horizontal, 4).padding(.top, 2)
        if idiom != .phone {
          if !device.online {
            Text("Offline").kitFont(.caption).padding(.horizontal, 6)
          } else if let data, data.cpu != nil || data.memoryUsed != nil {
            VStack(spacing: 6) {
              LabeledBar(label: "CPU", value: data.cpu, hue: .blue)
              LabeledBar(label: "Memory", value: device.memoryShare(data), hue: .purple)
            }
            .padding(.horizontal, 6)
          } else if ["ios", "ipados", "android"].contains(device.platform ?? "") {
            Text("No stats from phones").kitFont(.caption).padding(.horizontal, 6)
          }
          KeyValueLine(key: "Hub Network", value: device.overlay?.address ?? "–", mono: true)
            .padding(.horizontal, 6)
        }
      }
    }
    .task(id: device.online) {
      guard device.online, hub.require(permissions: "hub/devices/data"), !hub.isDemo else { return }
      do {
        for try await data in hub.client.devices.data(device.id) {
          self.data = data
        }
      } catch { }
    }
  }
}

/// Every device as a sortable table row (Office's 212 devices)
private struct DeviceTable: View {
  let devices: [Device]
  @Binding var selection: String?
  @Binding var sort: KitGridSort?

  var body: some View {
    let rows = sorted
    KitGrid(rows, columns: columns, selection: Binding {
      selection.map { [$0] } ?? []
    } set: { ids in
      withAnimation(.kit) { selection = ids.first }
    }, sort: $sort) {
      EmptyView()
    }
  }

  private var sorted: [Device] {
    let rows = devices
    guard let sort else { return rows }
    let key: (Device) -> String = switch sort.column {
    case "System": { $0.platform.map(Device.systemName) ?? "" }
    case "Status": { $0.online ? "0" : "1" }
    case "Services": { String(format: "%06d", $0.services.count) }
    case "Hub Network": { $0.overlay?.address ?? "" }
    default: { $0.name.lowercased() }
    }
    return rows.sorted { sort.ascending ? key($0) < key($1) : key($0) > key($1) }
  }

  private var columns: [KitGridColumn<Device>] {
    [
      KitGridColumn("Name", width: 260) { device in
        HStack(spacing: 8) {
          Tile(systemImage: Device.symbol(platform: device.platform), hue: .gray, size: 18)
          Text(device.name).lineLimit(1)
        }
      },
      KitGridColumn("System", width: 100, value: { $0.platform.map(Device.systemName) }),
      KitGridColumn("Status", width: 90) { device in
        Chip(device.online ? "Online" : "Offline", hue: device.online ? .green : .gray).controlSize(.small)
      },
      KitGridColumn("Services", width: 80, alignment: .trailing, value: { "\($0.services.count)" }),
      KitGridColumn("Hub Network", width: 130, mono: true, value: { $0.overlay?.address ?? "–" }),
      KitGridColumn("Seen", width: 110, value: { device in
        device.online ? "now" : device.lastSeen?.formatted(.relative(presentation: .named)) ?? "–"
      }),
    ]
  }
}

/// The selected device: what it is, its live resources, its services, and revoking it
struct DeviceInspector: View {
  let device: Device
  @Environment(Hub.self) private var hub
  @State private var data: DeviceData?
  @State private var isRevoking = false
  @State private var isRenaming = false
  @State private var name = ""

  var body: some View {
    let isThisDevice = device.key == hub.client.device?.key.publicKey
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      KitSection(device.name, meta: [device.statusText, isThisDevice ? "this \(KitDevice.name)" : ""], systemImage: Device.symbol(platform: device.platform), hue: .blue) {
        if let os = device.os {
          InspectorRow("System", value: [device.platform.map(Device.systemName), os, device.arch].compactMap { $0 }.joined(separator: " "), copyable: false)
        }
        if let parent = device.parent {
          InspectorRow("Runs in", value: parent, copyable: false)
        }
        if let overlay = device.overlay {
          InspectorRow("Hub Network", value: overlay.address)
        }
        InspectorRow("Safety code", value: DeviceKey.safetyCode(publicKey: device.key), copyable: false)
        InspectorRow("Key", value: "…" + device.key.suffix(8))
      } accessory: {
        if hub.require(permissions: "hub/device/rename") {
          Button("Rename", systemImage: "pencil") {
            name = device.name
            isRenaming = true
          }
          .buttonStyle(.kitIcon)
        }
      }
      if device.online, let data {
        KitSection("Resources", meta: ["live"], systemImage: "chart.bar", hue: .purple) {
          VStack(spacing: 8) {
            LabeledBar(label: "CPU", value: data.cpu, hue: .blue)
            LabeledBar(label: "Memory", value: device.memoryShare(data), hue: .purple)
            if let free = data.storageFree, let total = data.storageTotal, total > 0 {
              LabeledBar(label: "Disk", value: 1 - Double(free) / Double(total), hue: .orange)
            }
            if let battery = data.battery {
              LabeledBar(label: "Battery", value: battery, hue: .green)
            }
          }
          .padding(.horizontal, 8).padding(.vertical, 4)
        }
      }
      KitSection("Services", meta: [device.services.isEmpty ? "none" : "\(device.services.filter(\.online).count) running"], systemImage: "hexagon", hue: .accent) {
        ForEach(device.services) { service in
          SidebarRow(service.name ?? service.instance, subtitle: service.paths.prefix(3).joined(separator: " · ")) {
            Tile(systemImage: "hexagon", hue: service.online ? .blue : .gray, size: 18)
          } trailing: {
            StatusDot(hue: service.online ? .green : .gray, isHollow: !service.online)
          }
        }
      }
      if !isThisDevice && hub.require(permissions: "hub/device/revoke") {
        Button("Revoke \(device.name)…", role: .destructive) { isRevoking = true }
          .buttonStyle(.kit)
          .frame(maxWidth: .infinity)
      }
    }
    .task(id: "\(device.id)\(device.online)") {
      data = nil
      guard device.online, hub.require(permissions: "hub/devices/data"), !hub.isDemo else { return }
      do {
        for try await data in hub.client.devices.data(device.id) {
          self.data = data
        }
      } catch { }
    }
    .kitDialog(
      "Revoke \(device.name)?", isPresented: $isRevoking,
      message: device.services.count == 1
        ? "For a lost or compromised device. Its connections close, its service key is revoked, its grants and Hub Network peers are removed, and it can never be approved again."
        : "For a lost or compromised device. Its connections close, its \(device.services.count) service keys are revoked, its grants and Hub Network peers are removed, and it can never be approved again.",
      systemImage: "xmark.shield", hue: .red, confirm: "Revoke", role: .destructive
    ) {
      Task { try? await hub.client.devices.revoke(device.id) }
    }
    .alert("Rename Device", isPresented: $isRenaming) {
      TextField("Name", text: $name)
      Button("Cancel", role: .cancel) { }
      Button("Rename") {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { _ = try? await hub.client.devices.rename(device.id, to: name) }
      }
    }
  }
}

extension Device {
  /// "macOS", "Linux", "iPadOS"
  static func systemName(_ platform: String) -> String {
    switch platform {
    case "macos": "macOS"
    case "ios": "iOS"
    case "ipados": "iPadOS"
    case "visionos": "visionOS"
    case "tvos": "tvOS"
    case "watchos": "watchOS"
    case "linux": "Linux"
    case "windows": "Windows"
    case "android": "Android"
    default: platform.capitalized
    }
  }
  /// The card's line: system, what it runs, services, or when it was last seen
  @MainActor func cardLine(isThisDevice: Bool, compact: Bool) -> [String] {
    var parts = [String]()
    if !compact, let platform { parts.append(Device.systemName(platform)) }
    if isThisDevice { parts.append("this \(KitDevice.name)") }
    if online || compact {
      parts.append(services.count == 1 ? "1 service" : "\(services.count) services")
    }
    if !online, let lastSeen {
      parts.append("seen \(lastSeen.formatted(.relative(presentation: .named)))")
    }
    return parts
  }
  /// Memory in use, of the device's total
  func memoryShare(_ data: DeviceData) -> Double? {
    guard let used = data.memoryUsed, let total = capabilities?.memory, total > 0 else { return nil }
    return Double(used) / Double(total)
  }
}
#endif
