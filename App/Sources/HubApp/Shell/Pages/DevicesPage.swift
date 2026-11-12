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
  @HubState(\.attachRequests) private var attachRequests
  @KitStorage("devices.style") private var style = ListStyle.grid
  @State private var search = ""
  @State private var filter = DeviceFilter.all
  @State private var selection: String?
  @State private var pushed: String?
  @State private var sort: KitGridSort? = KitGridSort("Name")
  @Environment(\.kitIdiom) private var idiom

  private var approved: [Device] {
    devices.filter { $0.approved && !$0.revoked }
  }
  /// Requests an owner turned down: they don't ask again until allowed to
  private var denied: [Device] {
    devices.filter { $0.denied && !$0.approved && !$0.revoked }
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
        ForEach(attachRequests.prefix(3)) { request in
          AttachRequestBanner(request: request)
        }
        // One asking to attach is asked about above
        ForEach(pending.filter { device in !attachRequests.contains { $0.id == device.id } }.prefix(3)) { device in
          PendingDeviceBanner(device: device)
        }
        if !denied.isEmpty && hub.require(permissions: "hub/device/remove") {
          DeniedDevicesSection(devices: denied)
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
            message: "Devices join with an invite link or a pairing code from this \(KitDevice.nameInSentence)."
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
      .animation(.kit, value: attachRequests.map(\.id))
    } inspector: {
      if let device = selected {
        DeviceInspector(device: device)
      }
    }
    .pageToolbar(String(localized: "Devices"), meta: meta, systemImage: HubPage.devices.systemImage, hue: .blue) {
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
          .pageToolbar(device.name, meta: [device.statusText], systemImage: Device.symbol(platform: device.platform), hue: .blue) { }
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
      approved.count == 1 ? String(localized: "1 device") : String(localized: "\(approved.count) devices"),
      String(localized: "\(approved.filter(\.online).count) online"),
      pending.isEmpty ? "" : String(localized: "\(pending.count) waiting"),
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
    case .all: String(localized: "All")
    case .phones: String(localized: "Phones")
    case .computers: String(localized: "Computers")
    case .other: String(localized: "Other")
    case .offline: String(localized: "Offline")
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

/// A device asking to join: its safety code to compare on the device, Deny and Approve. Approve asks first: to compare
/// the code, or, when there's none that checks against the pinned hub key (an old hub, or a code that doesn't match),
/// in red, since anyone who reaches the hub can ask under any name (security audit apps M15, decisions 1.0 Hub 10).
struct PendingDeviceBanner: View {
  let device: PendingDevice
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  @State private var isApproving = false

  var body: some View {
    let name = device.name ?? String(localized: "A device")
    let code = hub.safetyCode(of: device)
    let message = MetaLine.join([
      device.platform.map(Device.systemName) ?? "",
      device.firstSeenDate.map { String(localized: "asked \($0.formatted(.relative(presentation: .named)))") } ?? "",
      code.map { String(localized: "check its safety code \($0) on the device") }
        ?? String(localized: "no safety code checks, so this may not be your device"),
    ])
    Banner(
      "\(name) wants to join \(hub.settings.name)", message: "\(message)",
      systemImage: Device.symbol(platform: device.platform), hue: code == nil ? .red : .orange
    ) {
      if hub.require(permissions: "hub/device/approve") {
        if idiom != .phone && hub.require(permissions: "hub/device/remove") {
          // Deny keeps the request turned down; removing it let the device, still connected, ask again at once (H-033).
          // Older hubs only remove.
          AsyncButton("Deny") {
            if hub.api.contains("hub/device/deny") {
              try await hub.client.devices.deny(device.id)
            } else {
              try await hub.client.devices.remove(device.id)
            }
          }
          .buttonStyle(.kit)
        }
        Button("Approve…") { isApproving = true }
          .buttonStyle(.kitPrimary)
      }
    }
    .kitDialog(
      code == nil ? "Approve \(name) Without a Safety Code?" : "Does \(name) Show \(code ?? "")?", isPresented: $isApproving,
      message: code == nil
        ? "This hub gives no safety code that checks against its key, so nothing shows this request came from your device. Anyone who can reach the hub can ask to join under any name, and an approved device can use what the hub shares. Approve only if you just asked from your own device and no one else could have."
        : "Approve only if the safety code on the device asking to join is \(code ?? ""). If it shows another code or none, deny it.",
      systemImage: code == nil ? "exclamationmark.shield" : "checkmark.shield", hue: code == nil ? .red : .blue,
      confirm: code == nil ? "Approve Without a Code" : "Codes Match, Approve", role: code == nil ? .destructive : nil
    ) {
      Task { _ = try? await hub.client.devices.approve(device.id) }
    }
  }
}

/// Devices whose request an owner denied (H-033): they stay refused until allowed to ask again, which makes a new
/// request with a new code to compare, or revoked, which refuses them for good and takes them off this list
struct DeniedDevicesSection: View {
  let devices: [Device]
  @Environment(Hub.self) private var hub
  @State private var revoking: Device?

  var body: some View {
    KitSection("Denied", meta: [devices.count == 1 ? String(localized: "1 device") : String(localized: "\(devices.count) devices")], systemImage: "hand.raised", hue: .gray) {
      ForEach(devices) { device in
        SidebarRow(device.name, subtitle: MetaLine.join([
          device.platform.map(Device.systemName) ?? "",
          String(localized: "can’t ask to join until you allow it"),
        ])) {
          Tile(systemImage: Device.symbol(platform: device.platform), hue: .gray, size: 18)
        } trailing: {
          HStack(spacing: 6) {
            AsyncButton("Allow to Ask Again") { try await hub.client.devices.remove(device.id) }
              .buttonStyle(.kit).controlSize(.small)
            if hub.require(permissions: "hub/device/revoke") {
              Button("Revoke…", role: .destructive) { revoking = device }.buttonStyle(.kit).controlSize(.small)
            }
          }
        }
      }
    }
    .kitDialog(
      "Revoke \(revoking?.name ?? "")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
      message: "It can never ask to join this hub again, and it leaves this list.",
      systemImage: "xmark.shield", hue: .red, confirm: "Revoke", role: .destructive
    ) {
      if let device = revoking { Task { try? await hub.client.devices.revoke(device.id) } }
    }
  }
}

/// A device asking to attach: its safety code to compare, and signing for it with this device's key
struct AttachRequestBanner: View {
  let request: AttachRequest
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let code = hub.safetyCode(of: request)
    let thisDevice = hub.client.device?.key
    let message = MetaLine.join([
      request.platform.map(Device.systemName) ?? "",
      String(localized: "it starts with nothing, you link what it gets"),
      code.map { String(localized: "check its safety code \($0) on the device") }
        ?? String(localized: "this hub gives no safety code to check"),
    ])
    Banner(
      "\(request.name) wants to attach to this \(KitDevice.nameInSentence)", message: "\(message)",
      systemImage: Device.symbol(platform: request.platform), hue: .orange
    ) {
      if idiom != .phone {
        AsyncButton("Deny") { try await hub.client.devices.dismissAttach(request.id) }.buttonStyle(.kit)
      }
      if code != nil, let thisDevice, let hubKey = hub.client.hubKey {
        AsyncButton(idiom == .phone ? "Attach" : "Attach…") {
          try await hub.client.devices.attach(request, signingWith: thisDevice, hubKey: hubKey)
        }
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
  @HubState(\.devices) private var devices
  @Environment(\.kitIdiom) private var idiom
  @State private var data: DeviceData?

  var body: some View {
    GridCard(isSelected: isSelected, action: action) {
      if idiom == .phone {
        // iPhone: two across, the tile over the name
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .top) {
            Tile(systemImage: Device.symbol(platform: device.platform), hue: device.online ? .blue : .gray, size: 30)
            Spacer()
            if let battery = data?.battery {
              Text("\(Int(battery * 100))%").kitFont(.caption)
            }
            StatusDot(hue: device.online ? .green : .gray, isHollow: !device.online)
          }
          Text(device.name).kitFont(.headline).lineLimit(1)
          Text(MetaLine.join(device.cardLine(isThisDevice: device.key == hub.client.device?.key.publicKey, compact: true, parent: devices.first { $0.id == device.attachedTo }?.name)))
            .kitFont(.caption).lineLimit(1)
        }
        .padding(6)
      } else {
      VStack(alignment: .leading, spacing: 8) {
        RichHeader(Text(device.name)) {
          Tile(systemImage: Device.symbol(platform: device.platform), hue: device.online ? .blue : .gray, size: idiom == .phone ? 30 : 24)
        } meta: {
          MetaLine(device.cardLine(isThisDevice: device.key == hub.client.device?.key.publicKey, compact: idiom == .phone, parent: devices.first { $0.id == device.attachedTo }?.name))
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
  @HubState(\.devices) private var everyone

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
      KitGridColumn("Under", width: 120, value: { device in everyone.first { $0.id == device.attachedTo }?.name ?? "–" }),
      KitGridColumn("System", width: 100, value: { $0.platform.map(Device.systemName) }),
      KitGridColumn("Status", width: 90) { device in
        Chip(device.online ? "Online" : "Offline", hue: device.online ? .green : .gray).controlSize(.small)
      },
      KitGridColumn("Services", width: 80, alignment: .trailing, value: { "\($0.services.count)" }),
      KitGridColumn("Hub Network", width: 130, mono: true, value: { $0.overlay?.address ?? "–" }),
      KitGridColumn("Seen", width: 110, value: { device in
        device.online ? String(localized: "now") : device.lastSeen?.formatted(.relative(presentation: .named)) ?? "–"
      }),
    ]
  }
}

/// The selected device: what it is, its live resources, its services, and revoking it
struct DeviceInspector: View {
  let device: Device
  @Environment(Hub.self) private var hub
  @HubState(\.networkAgents) private var networkAgents
  @HubState(\.networkGateways) private var gatewayStatuses
  @HubState(\.devices) private var devices
  @State private var data: DeviceData?
  @State private var isRevoking = false
  @State private var isRenaming = false
  @State private var name = ""

  /// This device's internet, when it offers it on the Hub Network (and isn't this device)
  private var gateway: HubNet.Device? {
    guard !gatewayStatuses.isEmpty, device.key != hub.client.device?.key.publicKey else { return nil }
    let keys = Set(networkAgents.filter { $0.deviceId == device.id }.map(\.key))
    return hub.net.devices.first { keys.contains($0.key) }
  }

  var body: some View {
    let isThisDevice = device.key == hub.client.device?.key.publicKey
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      KitSection(device.name, meta: [device.statusText, isThisDevice ? String(localized: "this \(KitDevice.nameInSentence)") : ""], systemImage: Device.symbol(platform: device.platform), hue: .blue) {
        if let os = device.os {
          InspectorRow("System", value: [device.platform.map(Device.systemName), os, device.arch].compactMap { $0 }.joined(separator: " "), copyable: false)
        }
        if let parent = device.attachedTo {
          InspectorRow("Attached to", value: devices.first { $0.id == parent }?.name ?? "…" + parent.suffix(8), copyable: false)
        }
        // Only what it says about itself: a parent's signature is what attaches a device
        if let parent = device.parent {
          InspectorRow("Says it runs in", value: parent, copyable: false)
        }
        if let overlay = device.overlay {
          InspectorRow("Hub Network", value: overlay.address)
        }
        if let code = hub.safetyCode(deviceKey: device.key, codeValue: device.codeValue) {
          InspectorRow("Safety code", value: code, copyable: false)
        }
        InspectorRow("Key", value: "…" + device.key.suffix(8))
        if let gateway {
          InternetGatewayRow(gateway: gateway, title: String(localized: "Internet"))
        }
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
        KitSection("Resources", meta: [String(localized: "live")], systemImage: "chart.bar", hue: .purple) {
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
      KitSection("Services", meta: [device.services.isEmpty ? String(localized: "none") : String(localized: "\(device.services.filter(\.online).count) running")], systemImage: "hexagon", hue: .accent) {
        ForEach(device.services) { service in
          SidebarRow(service.name ?? service.instance, subtitle: service.paths.prefix(3).joined(separator: " · ")) {
            Tile(systemImage: "hexagon", hue: service.online ? .blue : .gray, size: 18)
          } trailing: {
            StatusDot(hue: service.online ? .green : .gray, isHollow: !service.online)
          }
        }
      }
      if !device.revoked { DeviceLinksSection(device: device) }
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
      message: revokeMessage,
      systemImage: "xmark.shield", hue: .red, confirm: "Revoke", role: .destructive
    ) {
      Task { try? await hub.client.devices.revoke(device.id) }
    }
    .kitSheet(isPresented: $isRenaming) {
      NameSheet(title: String(localized: "Rename \(device.name)"), systemImage: Device.symbol(platform: device.platform), hue: .blue, confirm: String(localized: "Rename"), name: device.name) { name in
        Task { _ = try? await hub.client.devices.rename(device.id, to: name) }
      }
    }
  }

  private var revokeMessage: LocalizedStringKey {
    switch (device.services.count, devices.contains { $0.attachedTo == device.id && !$0.revoked }) {
    case (1, false):
      "For a lost or compromised device. Its connections close, its service key is revoked, its grants and Hub Network peers are removed, and it can never be approved again."
    case (1, true):
      "For a lost or compromised device. Its connections close, its service key is revoked, its grants and Hub Network peers are removed, and it can never be approved again. Every device attached below it is revoked too."
    case (let count, false):
      "For a lost or compromised device. Its connections close, its \(count) service keys are revoked, its grants and Hub Network peers are removed, and it can never be approved again."
    case (let count, true):
      "For a lost or compromised device. Its connections close, its \(count) service keys are revoked, its grants and Hub Network peers are removed, and it can never be approved again. Every device attached below it is revoked too."
    }
  }
}

/// A device's place in the chain and what it holds, for owners: "Only what I link". A new child holds nothing. A grant
/// the owner links passes to children the owner links, and comes back as a copy on them.
private struct DeviceLinksSection: View {
  let device: Device
  @Environment(Hub.self) private var hub
  @HubState(\.devices) private var devices
  @HubState(\.grants) private var grants
  @State private var isAdding = false
  @State private var isDetaching = false

  private var children: [Device] { devices.filter { $0.attachedTo == device.id && !$0.revoked } }
  private var held: [Grant] { grants.filter { $0.subject == .device(device.id) } }

  var body: some View {
    if hub.require(permissions: "hub/grants") {
      if device.attachedTo != nil {
        KitSection("Link to parent", meta: [device.linked == true ? String(localized: "gets what you link") : String(localized: "gets nothing")], systemImage: "link", hue: .blue) {
          HStack {
            Text("Gets linked grants").kitFont(.body)
            Spacer()
            linkToggle(device, title: String(localized: "Gets linked grants"))
          }
          .padding(.horizontal, 8).padding(.vertical, 2)
          Button("Detach from Parent", role: .destructive) { isDetaching = true }
            .buttonStyle(.kit).frame(maxWidth: .infinity)
        }
      }
      if !children.isEmpty {
        KitSection("Attached", meta: ["\(children.count)"], systemImage: "point.3.connected.trianglepath.dotted", hue: .blue) {
          ForEach(children) { child in
            SidebarRow("\(child.name)", subtitle: child.linked == true ? String(localized: "gets what you link") : String(localized: "gets nothing")) {
              Tile(systemImage: Device.symbol(platform: child.platform), hue: child.online ? .blue : .gray, size: 18)
            } trailing: {
              linkToggle(child, title: String(localized: "Linked"))
            }
          }
        }
      }
      KitSection("Access", meta: [held.isEmpty ? String(localized: "nothing granted") : "\(held.count)"], systemImage: "key", hue: .orange) {
        ForEach(held) { grant in
          SidebarRow(grant.object.title, subtitle: subtitle(of: grant)) {
            Tile(systemImage: grant.copyOf == nil ? "key" : "link", hue: grant.copyOf == nil ? .orange : .blue, size: 18)
          } trailing: {
            if grant.copyOf == nil {
              HStack(spacing: 6) {
                if !children.isEmpty {
                  Toggle("Passes down", isOn: Binding { grant.linked == true } set: { linked in
                    Task { _ = try? await hub.client.devices.setGrantLinked(grant.id, linked) }
                  })
                  .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
                }
                AsyncButton("Remove", systemImage: "xmark") { try await hub.client.devices.removeGrant(grant.id) }
                  .buttonStyle(.kitIcon)
              }
            }
          }
        }
      } accessory: {
        Button("Grant", systemImage: "plus") { isAdding = true }.buttonStyle(.kitIcon)
      }
      .kitSheet(isPresented: $isAdding) {
        GrantSheet(device: device) { object in
          Task { _ = try? await hub.client.devices.addGrant(.device(device.id), object) }
        }
      }
      .kitDialog(
        "Detach \(device.name)?", isPresented: $isDetaching,
        message: "What it got through this link goes. It stays approved, with what you gave it directly.",
        systemImage: "link", hue: .orange, confirm: "Detach", role: .destructive
      ) {
        Task { _ = try? await hub.client.devices.detach(device.id) }
      }
    }
  }

  private func linkToggle(_ child: Device, title: String) -> some View {
    Toggle(title, isOn: Binding { child.linked == true } set: { linked in
      Task { _ = try? await hub.client.devices.setLinked(child.id, linked) }
    })
    .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
  }

  private func subtitle(of grant: Grant) -> String {
    guard let source = grant.copyOf else { return grant.linked == true ? String(localized: "passes down") : String(localized: "only this device") }
    guard case .device(let parent)? = grants.first(where: { $0.id == source })?.subject else { return String(localized: "from its parent") }
    return String(localized: "from \(devices.first { $0.id == parent }?.name ?? String(localized: "its parent"))")
  }
}

/// Grants a device a path, or everything under `path/*`
private struct GrantSheet: View {
  let device: Device
  let action: (Grant.Object) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var path = ""

  private var object: Grant.Object? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.hasSuffix("*") ? .prefix(String(trimmed.dropLast())) : .path(trimmed)
  }

  var body: some View {
    KitSheet(title: "Grant \(device.name)", meta: "a path, or everything under s3/*", systemImage: "key", hue: .orange) {
      FormCard {
        FormRow("Path", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
          TextField("s3/read", text: $path).kitField(mono: true, content: .verbatim).frame(maxWidth: 240)
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Grant") {
        if let object { action(object) }
        dismiss()
      }
      .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(object == nil)
    }
  }
}

extension Grant.Object {
  var title: String {
    switch self {
    case .path(let path): path
    case .prefix(let prefix): prefix + "*"
    case .share(let share): String(localized: "Share \(String(share.prefix(8)))")
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
  @MainActor func cardLine(isThisDevice: Bool, compact: Bool, parent: String? = nil) -> [String] {
    var parts = [String]()
    if !compact, let platform { parts.append(Device.systemName(platform)) }
    if isThisDevice { parts.append(String(localized: "this \(KitDevice.nameInSentence)")) }
    if let parent { parts.append(String(localized: "under \(parent)")) }
    if online || compact {
      parts.append(services.count == 1 ? String(localized: "1 service") : String(localized: "\(services.count) services"))
    }
    if !online, let lastSeen {
      parts.append(String(localized: "seen \(lastSeen.formatted(.relative(presentation: .named)))"))
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
