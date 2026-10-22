//
//  AccessPages.swift
//  Hub
//
//  Who may use the hub: Connections (grouped cards), Requests (services asking to post APIs), Lockdown (trusted
//  keys only) and Permissions (groups against permissions).
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

// MARK: - Connections

struct ConnectionsPage: View {
  @Environment(Hub.self) private var hub
  @HubState(\.users) private var users
  @HubState(\.groups) private var groups
  @HubState(\.hostPending) private var pending
  @HubState(\.whitelist) private var whitelist
  @AppStorage("connections.style") private var style = ListStyle.grid
  @State private var search = ""
  @State private var selection: String?
  @State private var pushed: String?
  @Environment(\.kitIdiom) private var idiom

  private var shown: [Hub.User] {
    users.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.key ?? "").localizedCaseInsensitiveContains(search) }
  }
  /// Users by group, in the hub's group order, then the ones without a group
  private var sections: [(name: String?, users: [Hub.User])] {
    let names = groups.groups.map(\.name)
    var result = names.map { name in (name: Optional(name), users: shown.filter { $0.group == name }) }.filter { !$0.users.isEmpty }
    let others = shown.filter { user in user.group.map { !names.contains($0) } ?? true }
    if !others.isEmpty { result.append((nil, others)) }
    return result
  }

  var body: some View {
    PageWithInspector(name: "connections", showsInspector: selected != nil) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          if !pending.list.isEmpty && hub.host.canManage {
            ServiceRequestsCard(items: pending.list)
          }
          if users.isEmpty {
            if hub.api.isEmpty { LoadingCards() } else {
              EmptyState(systemImage: "wifi", title: "No Connections", message: "Devices and services that connect to \(hub.settings.name) show here.")
                .padding(.top, 60)
            }
          }
          ForEach(sections, id: \.name) { section in
            GroupHeader(name: section.name, count: section.users.count, permissions: groups.groups.first { $0.name == section.name }?.permissions.count)
            if style == .grid || idiom == .phone {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 150 : 180), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
                ForEach(section.users) { user in
                  ConnectionCard(user: user, isMe: user.key == hub.key, isTrusted: user.key.map(whitelist.users.contains) ?? false, isSelected: selection == user.id) {
                    select(user.id)
                  }
                }
              }
            } else {
              VStack(spacing: 2) {
                ForEach(section.users) { user in
                  SidebarRow(user.name.isEmpty ? "Unauthorized" : user.name, subtitle: user.line(isMe: user.key == hub.key)) {
                    Tile(systemImage: user.icon.symbol?.name ?? "hexagon", hue: .gray, size: 20)
                  } trailing: {
                    StatusDot(hue: user.key == nil ? .orange : .green)
                  }
                  .action { select(user.id) }
                }
              }
              .padding(4)
              .kitSurface(.card)
            }
          }
        }
        .padding(KitMetrics.gutter)
        .padding(.bottom, 24)
      }
    } inspector: {
      if let user = selected {
        ConnectionInspector(user: user)
      }
    }
    .kitToolbar("Connections", meta: PageMeta.parts(hub, ["\(users.filter { $0.key != nil }.count) connected", pending.list.isEmpty ? "" : "\(pending.list.count) requests"]), systemImage: HubPage.connections.systemImage, hue: .teal) {
      if idiom != .phone {
        ListStyleSwitch(style: $style)
      }
      if hub.canLockdown {
        ToolGroup {
          Button("Lockdown", systemImage: "lock.shield") { Navigator.main.open(hub, .lockdown) }
        }
      }
      if idiom != .phone {
        KitSearchField(text: $search, prompt: "Name or key").frame(width: 180)
      }
    }
    .navigationDestination(item: $pushed) { id in
      if let user = users.first(where: { $0.id == id }) {
        ScrollView { ConnectionInspector(user: user).padding(KitMetrics.gutter) }
          .kitPane(.content)
          .kitToolbar(user.name, meta: [user.group?.capitalized ?? "No group"], systemImage: user.icon.symbol?.name ?? "hexagon", hue: .gray) { }
          .hub(hub)
      }
    }
  }

  private var selected: Hub.User? {
    selection.flatMap { id in users.first { $0.id == id } }
  }

  private func select(_ id: String) {
    if idiom == .phone {
      pushed = id
    } else {
      withAnimation(.kit) { selection = selection == id ? nil : id }
    }
  }
}

/// A permission group's title over its cards
private struct GroupHeader: View {
  let name: String?
  let count: Int
  let permissions: Int?

  var body: some View {
    RichHeader(name?.capitalized ?? "No group", meta: [
      count == 1 ? "1 connection" : "\(count) connections",
      name == "owners" ? "every permission" : permissions.map { $0 == 1 ? "1 permission" : "\($0) permissions" } ?? "no permissions",
    ], systemImage: name == "owners" ? "key" : name == nil ? "questionmark" : "person.2", hue: name == "owners" ? .red : name == nil ? .gray : .purple)
    .padding(.horizontal, 4).padding(.top, 6)
  }
}

private struct ConnectionCard: View {
  let user: Hub.User
  let isMe: Bool
  let isTrusted: Bool
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    GridCard(isSelected: isSelected, action: action) {
      VStack(alignment: .leading, spacing: 8) {
        RichHeader(Text(user.name.isEmpty ? "Unauthorized" : user.name)) {
          Tile(systemImage: user.icon.symbol?.name ?? "hexagon", hue: .gray, size: 24)
        } meta: {
          Text(user.key.map { "…" + $0.suffix(8) } ?? "no key").font(.system(size: 11, design: .monospaced)).foregroundStyle(.kitSecondary)
        } accessory: {
          HStack(spacing: 5) {
            if isTrusted { Image(systemName: "checkmark.shield").font(.system(size: 11)).foregroundStyle(Hue.red.text) }
            StatusDot(hue: user.key == nil ? .orange : .green)
          }
        }
        .titleAccessory { if isMe { Chip("You").controlSize(.small) } }
        .padding(.horizontal, 4).padding(.top, 2)
        Text(user.services == 0 && user.apps == 0 ? "No services" : MetaLine.join([
          user.services > 0 ? (user.services == 1 ? "1 service" : "\(user.services) services") : "",
          user.apps > 0 ? (user.apps == 1 ? "1 app" : "\(user.apps) apps") : "",
        ]))
        .kitFont(.caption).padding(.horizontal, 6)
      }
    }
  }
}

/// A connection: its key, its group (pick one), Lockdown trust, and removing it from its group
struct ConnectionInspector: View {
  let user: Hub.User
  @Environment(Hub.self) private var hub
  @HubState(\.groups) private var groups
  @HubState(\.whitelist) private var whitelist

  var body: some View {
    let isTrusted = user.key.map(whitelist.users.contains) ?? false
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      RichHeader(Text(user.name.isEmpty ? "Unauthorized" : user.name), size: .title) {
        Tile(systemImage: user.icon.symbol?.name ?? "hexagon", hue: .gray, size: 28)
      } meta: {
        MetaLine([user.group?.capitalized ?? "No group", user.key == hub.key ? "this app" : ""])
      } accessory: {
        EmptyView()
      }
      .padding(.horizontal, 4)
      if isTrusted { Chip("Trusted", hue: .blue).controlSize(.small).padding(.horizontal, 4) }
      if let key = user.key {
        KitSection("Key", meta: ["Ed25519"], systemImage: "key", hue: .red) {
          InspectorRow("Key", copyText: key) {
            Text("…" + key.suffix(16)).kitFont(.mono).lineLimit(1)
          }
        }
        if hub.canManageGroups && !groups.groups.isEmpty {
          KitSection("Group", meta: [user.group?.capitalized ?? "No group"], systemImage: "person.2", hue: .purple) {
            ForEach(groups.groups) { group in
              SidebarRow(group.name.capitalized, systemImage: group.name == "owners" ? "key" : "person.2") {
                if user.group == group.name { Image(systemName: "checkmark").foregroundStyle(Hue.accent.text) }
              }
              .action { Task { try? await setGroup(group.name, key: key) } }
            }
            SidebarRow("No group", systemImage: "questionmark") {
              if user.group == nil { Image(systemName: "checkmark").foregroundStyle(Hue.accent.text) }
            }
            .action { Task { try? await setGroup(nil, key: key) } }
          }
        }
        if hub.canLockdown {
          KitSection("Lockdown", meta: [isTrusted ? "Trusted" : "Not trusted"], systemImage: "lock.shield", hue: .blue) {
            Toggle("Can connect in Lockdown", isOn: Binding { isTrusted } set: { trust in
              Task { try? await hub.lockdown(trust ? SetLockdown(add: [key]) : SetLockdown(remove: [key])) }
            })
            .toggleStyle(.kitSwitch)
            .padding(8)
          }
        }
        HStack {
          Button("Copy Key") { key.copyToClipboard() }.buttonStyle(.kit)
          if let group = user.group, hub.canManageGroups {
            AsyncButton("Remove from \(group.capitalized)") { try await hub.remove(key: key, group: group) }
              .buttonStyle(.kit).foregroundStyle(Hue.red.text)
          }
        }
        .controlSize(.small)
      } else {
        Text("A connection without a key can only call the APIs anyone may call.").kitFont(.caption).padding(.horizontal, 4)
      }
    }
  }

  private func setGroup(_ group: String?, key: String) async throws {
    if let current = user.group, current != group {
      try await hub.remove(key: key, group: current)
    }
    if let group, group != user.group {
      try await hub.add(key: key, group: group)
    }
  }
}

extension Hub.User {
  func line(isMe: Bool) -> String {
    MetaLine.join([
      key.map { "…" + $0.suffix(8) } ?? "no key", isMe ? "you" : "",
      services > 0 ? (services == 1 ? "1 service" : "\(services) services") : "",
      apps > 0 ? (apps == 1 ? "1 app" : "\(apps) apps") : "",
    ])
  }
}

/// Services asking to post APIs: each one's APIs and Allow
struct ServiceRequestsCard: View {
  let items: [PendingList.Item]
  @Environment(Hub.self) private var hub

  var body: some View {
    KitSection("Requests", meta: ["\(items.count == 1 ? "1 service asks" : "\(items.count) services ask") to post APIs", "they get only the APIs listed"], systemImage: "clock", hue: .orange) {
      ForEach(items) { item in
        SidebarRow(item.name, subtitle: MetaLine.join([item.pending.joined(separator: ", "), "…" + item.id.suffix(8)])) {
          Tile(systemImage: "hexagon", hue: .orange, size: 20)
        } trailing: {
          AsyncButton("Allow") { try await hub.host.allow(key: item.id, paths: item.pending) }
            .buttonStyle(.kitPrimary).controlSize(.small)
        }
      }
    }
  }
}

// MARK: - Requests

struct RequestsPage: View {
  @Environment(Hub.self) private var hub
  @HubState(\.hostPending) private var pending
  @HubState(\.pendingDevices) private var devices
  @State private var selection: String?
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    PageWithInspector(name: "requests", showsInspector: selected != nil) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          ForEach(devices) { device in
            PendingDeviceBanner(device: device)
          }
          if pending.list.isEmpty && devices.isEmpty {
            EmptyState(
              systemImage: "checkmark.shield", title: "Nothing Waiting",
              message: "When a service asks to post APIs, it shows here and as a count on \(hub.settings.name)’s card."
            )
            .padding(.top, 80)
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 280 : 300), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
            ForEach(pending.list) { item in
              GridCard(isSelected: selection == item.id, action: { withAnimation(.kit) { selection = selection == item.id ? nil : item.id } }) {
                VStack(alignment: .leading, spacing: 8) {
                  RichHeader(item.name, meta: ["…" + item.id.suffix(8)], systemImage: "hexagon", hue: .orange)
                    .padding(.horizontal, 4).padding(.top, 2)
                  ChipFlow(items: item.pending)
                    .padding(.horizontal, 6)
                  HStack {
                    Text("Gets only these APIs").kitFont(.caption)
                    Spacer()
                    if hub.host.canManage {
                      AsyncButton("Allow") { try await hub.host.allow(key: item.id, paths: item.pending) }
                        .buttonStyle(.kitPrimary).controlSize(.small)
                    }
                  }
                  .padding(.horizontal, 6)
                }
              }
            }
          }
        }
        .padding(KitMetrics.gutter)
      }
    } inspector: {
      if let item = selected {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          RichHeader(item.name, meta: ["waiting"], size: .title, systemImage: "hexagon", hue: .orange)
          KitSection("Key", systemImage: "key", hue: .red) {
            InspectorRow("Key", copyText: item.id) { Text("…" + item.id.suffix(16)).kitFont(.mono) }
          }
          KitSection("Wants to post", meta: [item.pending.count == 1 ? "1 API" : "\(item.pending.count) APIs"], systemImage: "hexagon", hue: .blue) {
            ForEach(item.pending, id: \.self) { path in
              InspectorRow(path, value: "", copyable: false)
            }
          }
        }
      }
    }
    .kitToolbar("Requests", meta: PageMeta.parts(hub, ["\(pending.list.count + devices.count) waiting", "services that want to post APIs"]), systemImage: HubPage.requests.systemImage, hue: .orange) { }
  }

  private var selected: PendingList.Item? {
    selection.flatMap { id in pending.list.first { $0.id == id } }
  }
}

/// API paths as chips that wrap
struct ChipFlow: View {
  let items: [String]
  var body: some View {
    FlowLayout(spacing: 4) {
      ForEach(items, id: \.self) { item in
        Chip(Text(item).monospaced(), hue: .orange).controlSize(.small)
      }
    }
  }
}

// MARK: - Lockdown

struct LockdownPage: View {
  @Environment(Hub.self) private var hub
  @HubState(\.users) private var users
  @HubState(\.whitelist) private var whitelist
  @State private var search = ""
  @State private var isOn = false
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let keyed = users.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    let trusted = keyed.filter { $0.key.map(whitelist.users.contains) ?? false }
    let untrusted = keyed.filter { !($0.key.map(whitelist.users.contains) ?? false) }
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        HStack(spacing: 12) {
          Tile(systemImage: "lock.shield", hue: .blue, size: 36)
          VStack(alignment: .leading, spacing: 2) {
            Text(whitelist.enabled ? "Lockdown is on" : "Lockdown is off").kitFont(.headline)
            Text(whitelist.enabled
                 ? "Only trusted devices connect. The rest are refused until you trust them."
                 : "Any device with a key can connect and ask for APIs. When it’s on, only trusted devices connect; the rest are refused until you trust them.")
              .kitFont(.caption)
          }
          Spacer()
          Toggle("Lockdown", isOn: $isOn).toggleStyle(.kitSwitch).labelsHidden()
        }
        .padding(12)
        .kitSurface(.card)
        if !whitelist.enabled && !untrusted.isEmpty {
          Banner(
            untrusted.count == 1 ? "1 connection would be refused" : "\(untrusted.count) connections would be refused",
            message: "\(ListFormatter.localizedString(byJoining: untrusted.prefix(3).map { $0.name.isEmpty ? "an unknown device" : $0.name })) aren’t trusted. Trust them first, or turn Lockdown on and they’ll be disconnected.",
            systemImage: "clock", hue: .orange
          ) {
            let keys = untrusted.compactMap(\.key)
            if !keys.isEmpty {
              AsyncButton(keys.count == 1 ? "Trust" : "Trust All \(keys.count)") { try await hub.lockdown(SetLockdown(add: keys)) }
                .buttonStyle(.kit)
            }
          }
        }
        section("Trusted", meta: "connect during Lockdown", trusted, isTrusted: true)
        section("Not trusted", meta: whitelist.enabled ? "refused while Lockdown is on" : "", untrusted, isTrusted: false)
      }
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
    }
    .kitPane(.content)
    .task(id: whitelist.enabled) { isOn = whitelist.enabled }
    .onChange(of: isOn) { _, isOn in
      guard isOn != whitelist.enabled else { return }
      Task { try? await hub.lockdown(SetLockdown(enabled: isOn)) }
    }
    .kitToolbar("Lockdown", meta: PageMeta.parts(hub, [whitelist.enabled ? "On" : "Off", "\(trusted.count) of \(keyed.count) trusted"]), systemImage: HubPage.lockdown.systemImage, hue: .blue) {
      if idiom != .phone {
        KitSearchField(text: $search, prompt: "Name or key").frame(width: 180)
      }
    }
  }

  @ViewBuilder
  private func section(_ title: String, meta: String, _ users: [Hub.User], isTrusted: Bool) -> some View {
    if !users.isEmpty {
      HStack(spacing: 6) {
        Text(title).kitFont(.headline)
        Text(MetaLine.join(["\(users.count)", meta])).kitFont(.caption)
      }
      .padding(.horizontal, 4).padding(.top, 4)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 280 : 260), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
        ForEach(users) { user in
          GridCard {
            VStack(alignment: .leading, spacing: 6) {
              RichHeader(Text(user.name.isEmpty ? "Unauthorized" : user.name)) {
                Tile(systemImage: user.icon.symbol?.name ?? "hexagon", hue: .gray, size: 24)
              } meta: {
                MetaLine([user.group?.capitalized ?? "No group", user.key.map { "…" + $0.suffix(8) } ?? "no key"])
              } accessory: {
                HStack(spacing: 8) {
                  StatusDot(hue: user.key == nil ? .orange : .green)
                  if let key = user.key {
                    Toggle("Trusted", isOn: Binding { isTrusted } set: { trust in
                      Task { try? await hub.lockdown(trust ? SetLockdown(add: [key]) : SetLockdown(remove: [key])) }
                    })
                    .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
                    .disabled(user.key == hub.key)
                  }
                }
              }
              .padding(.horizontal, 4).padding(.top, 2)
              Text(user.key == hub.key ? "You · always trusted" : !isTrusted && whitelist.enabled ? "Refused while Lockdown is on" : "")
                .kitFont(.caption).padding(.horizontal, 6)
            }
          }
        }
      }
    }
  }
}

// MARK: - Permissions

struct PermissionsPage: View {
  @Environment(Hub.self) private var hub
  @HubState(\.permissions) private var permissions
  @HubState(\.groups) private var groups
  @State private var search = ""
  @State private var edits: [String: Set<String>] = [:]
  @State private var selectedGroup: String?
  @State private var isAdding = false
  @State private var newName = ""
  @State private var collapsed: Set<String> = []
  @Environment(\.kitIdiom) private var idiom

  /// A group's permissions with the unsaved edits
  private func granted(_ group: GroupList.Group) -> Set<String> {
    edits[group.name] ?? group.permissions
  }
  private var canEdit: Bool { hub.require(permissions: "hub/group/update") }

  var body: some View {
    PageWithInspector(name: "permissions", showsInspector: selectedGroup != nil) {
      ScrollView([.vertical, .horizontal]) {
        if groups.groups.isEmpty && !permissions.sections.isEmpty {
          Banner(
            "No permission groups yet",
            message: "A group gives its connections the permissions you tick. Owners always have every permission.",
            systemImage: "person.2", hue: .purple
          ) {
            if canEdit {
              Button("New Group…") { isAdding = true }.buttonStyle(.kitPrimary)
            }
          }
          .frame(maxWidth: 720)
          .padding([.horizontal, .top], KitMetrics.gutter)
        }
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 2) {
          headerRow
          ForEach(permissions.sections) { section in
            sectionRows(section)
          }
        }
        .kitFont(.body)
        .padding(KitMetrics.gutter)
        .disabled(!canEdit)
      }
    } inspector: {
      if let group = groups.groups.first(where: { $0.name == selectedGroup }) {
        GroupInspector(group: group, edits: $edits)
      }
    }
    .kitToolbar("Permissions", meta: PageMeta.parts(hub, [
      groups.groups.count == 1 ? "1 group" : "\(groups.groups.count) groups",
      "\(permissions.sections.reduce(0) { $0 + $1.permissions.count }) permissions",
      edits.isEmpty ? "" : "\(edits.count) unsaved",
    ]), systemImage: HubPage.permissions.systemImage, hue: .orange) {
      if idiom != .phone {
        KitSearchField(text: $search, prompt: "Permission or API").frame(width: 200)
      }
      if canEdit {
        ToolGroup {
          Button("New Group", systemImage: "plus") { isAdding = true }
        }
      }
    }
    .alert("New Group", isPresented: $isAdding) {
      TextField("Name", text: $newName)
      Button("Cancel", role: .cancel) { newName = "" }
      Button("Create") {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        Task {
          try? await hub.client.send("hub/group/update", PermissionGroups.UpdateGroup(group: name, set: []))
          selectedGroup = name
        }
      }
    }
  }

  private var headerRow: some View {
    GridRow {
      Text("Permission").kitFont(.caption).frame(width: 200, alignment: .leading)
      Text("API").kitFont(.caption).frame(width: 220, alignment: .leading)
      ForEach(groups.groups) { group in
        groupHeader(group)
      }
    }
  }

  private func groupHeader(_ group: GroupList.Group) -> some View {
    let index = groups.groups.firstIndex { $0.name == group.name } ?? 0
    return Button { withAnimation(.kit) { selectedGroup = group.name } } label: {
      VStack(spacing: 1) {
        StatusDot(hue: Hue.lane(index), size: 6)
        Text(group.name.capitalized).kitFont(.caption).fontWeight(.semibold).foregroundStyle(.kitLabel)
        Text(edits[group.name] == nil ? "\(group.permissions.count)" : "edited").font(.system(size: 9)).foregroundStyle(.kitTertiary)
      }
      .frame(width: 84).padding(.vertical, 4)
      .background(selectedGroup == group.name ? AnyShapeStyle(Hue.accent.soft()) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func sectionRows(_ section: PermissionList.Section) -> some View {
    let shown = section.permissions.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || section.name.localizedCaseInsensitiveContains(search) }
    if !shown.isEmpty {
      sectionHeader(section)
      if !collapsed.contains(section.name) {
        ForEach(shown, id: \.self) { permission in
          permissionRow(section, permission)
        }
      }
    }
  }

  private func sectionHeader(_ section: PermissionList.Section) -> some View {
    let paths = section.paths
    return GridRow {
      Button { withAnimation(.kit) { collapsed.formSymmetricDifference([section.name]) } } label: {
        HStack(spacing: 6) {
          Image(systemName: collapsed.contains(section.name) ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
          Text(section.name).fontWeight(.semibold)
          Text("\(section.permissions.count)").kitFont(.caption)
        }
      }
      .buttonStyle(.plain)
      .frame(width: 200, alignment: .leading)
      Color.clear.frame(width: 220, height: 1)
      ForEach(groups.groups) { group in
        let count = paths.filter(granted(group).contains).count
        check(count == paths.count ? .on : count == 0 ? .off : .mixed(count, paths.count)) {
          toggle(group, paths, on: count != paths.count)
        }
      }
    }
    .padding(.vertical, 6)
    .background(.kitFillSoft, in: .rect(cornerRadius: 6))
  }

  private func permissionRow(_ section: PermissionList.Section, _ permission: String) -> some View {
    let path = section.path(of: permission)
    return GridRow {
      Text(permission).padding(.leading, 22).frame(width: 200, alignment: .leading).lineLimit(1)
      Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.kitTertiary).frame(width: 220, alignment: .leading).lineLimit(1)
      ForEach(groups.groups) { group in
        let isOn = granted(group).contains(path)
        check(isOn ? .on : .off) {
          toggle(group, [path], on: !isOn)
        }
      }
    }
    .padding(.vertical, 5)
  }

  private enum Check { case on, off, mixed(Int, Int) }

  private func check(_ state: Check, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Group {
        switch state {
        case .on:
          Image(systemName: "checkmark.square.fill").foregroundStyle(Hue.accent.fill)
        case .off:
          Image(systemName: "square").foregroundStyle(.kitTertiary)
        case .mixed(let count, let total):
          HStack(spacing: 2) {
            Image(systemName: "minus.square.fill").foregroundStyle(Hue.accent.fill)
            Text("\(count)/\(total)").font(.system(size: 9)).foregroundStyle(.kitSecondary)
          }
        }
      }
      .font(.system(size: 14))
      .frame(width: 84)
    }
    .buttonStyle(.plain)
  }

  private func toggle(_ group: GroupList.Group, _ paths: [String], on: Bool) {
    var set = granted(group)
    if on { set.formUnion(paths) } else { set.subtract(paths) }
    withAnimation(.kit) {
      edits[group.name] = set == group.permissions ? nil : set
      selectedGroup = group.name
    }
  }
}

/// A group: its members, its unsaved changes with Save and Revert, and deleting it
private struct GroupInspector: View {
  let group: GroupList.Group
  @Binding var edits: [String: Set<String>]
  @Environment(Hub.self) private var hub
  @HubState(\.users) private var users
  @State private var isDeleting = false

  var body: some View {
    let members = users.filter { $0.group == group.name }
    let edited = edits[group.name]
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      KitSection(group.name.capitalized, meta: [members.count == 1 ? "1 member" : "\(members.count) members", "\(group.permissions.count) permissions"], systemImage: "person.2", hue: .purple) {
        ForEach(members) { user in
          SidebarRow(user.name, subtitle: user.key.map { "…" + $0.suffix(8) }) {
            Tile(systemImage: user.icon.symbol?.name ?? "hexagon", hue: .gray, size: 18)
          } trailing: {
            EmptyView()
          }
        }
        if members.isEmpty {
          Text("No one is in this group yet. Pick a group for a connection on Connections.").kitFont(.caption).padding(8)
        }
      }
      if let edited {
        let added = edited.subtracting(group.permissions)
        let removed = group.permissions.subtracting(edited)
        KitSection("\(added.count + removed.count) unsaved changes", meta: ["members get them when you save"], systemImage: "clock", hue: .red) {
          ForEach(Array(added).sorted(), id: \.self) { path in
            InspectorRow(path, copyText: nil) { Chip("Granted", hue: .green).controlSize(.small) }
          }
          ForEach(Array(removed).sorted(), id: \.self) { path in
            InspectorRow(path, copyText: nil) { Chip("Removed", hue: .red).controlSize(.small) }
          }
          HStack {
            Spacer()
            Button("Revert") { withAnimation(.kit) { edits[group.name] = nil } }.buttonStyle(.kit)
            AsyncButton("Save") {
              try await hub.client.send("hub/group/update", PermissionGroups.UpdateGroup(group: group.name, set: Array(edited)))
              withAnimation(.kit) { edits[group.name] = nil }
            }
            .buttonStyle(.kitPrimary)
          }
          .controlSize(.small)
          .padding(6)
        }
      }
      if group.name != "owners" && hub.require(permissions: "hub/group/remove") {
        Button("Delete \(group.name.capitalized)…", role: .destructive) { isDeleting = true }
          .buttonStyle(.kit).frame(maxWidth: .infinity)
      }
    }
    .kitDialog("Delete \(group.name.capitalized)?", isPresented: $isDeleting, message: "Its members lose its permissions.", systemImage: "trash", hue: .red, confirm: "Delete", role: .destructive) {
      Task { try? await hub.client.send("hub/group/remove", group.name) }
    }
  }
}

extension PermissionList.Section {
  /// The API path a permission's name stands for (`hub/group/names` maps paths to "Section: Name")
  func path(of permission: String) -> String {
    pathsByName[permission] ?? permission
  }
  var paths: [String] { permissions.map(path(of:)) }
}
#endif
