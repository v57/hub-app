//
//  NetworkCard.swift
//  Hub
//
//  The Hub Network card on the main screen (the sidebar's bottom on the Mac and iPad, the root list on iPhone): the
//  network's switch for this device, and whose internet it uses. A device is on one hub's network at a time, so the
//  card shows that network whichever hub is open. Its title opens the Hub Network page.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct HubNetworkCard: View {
  @State private var hubs = Hubs.main
  @State private var navigator = Navigator.main
  /// The hub the installed network profile belongs to
  @State private var profileHub: URL?

  var body: some View {
    Group {
      if let hub = Self.hub(profile: profileHub) {
        NetworkCardContent().hub(hub).id(hub.id)
      }
    }
#if os(macOS)
    // Keep This Mac Awake holds while any hub's network uses this Mac's internet
    .onChange(of: hubs.list.contains { $0.net.isSharing }, initial: true) { _, sharing in
      KeepAwake.main.update(sharing: sharing)
    }
#endif
    .task {
#if DEBUG
      guard !HubDemo.isOn else { return }
#endif
      profileHub = (try? PacketTunnelController().installedConfiguration())?.hubURL
      if let hub = hubs.list.first(where: { $0.settings.address == profileHub }), hub.isConnected {
        await hub.net.restoreIfActive()
      }
    }
  }

  /// The hub whose network the card shows: the one this device is on, else the open hub's
  @MainActor static func hub(profile: URL?) -> Hub? {
    let list = Hubs.main.list
    if let joined = list.first(where: \.net.isJoined) { return joined }
    if let profile, let hub = list.first(where: { $0.settings.address == profile }), hub.canViewNetwork { return hub }
    if let open = Navigator.main.openHub, open.canViewNetwork { return open }
    return nil
  }
}

private struct NetworkCardContent: View {
  var facts = NetworkFacts()
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  @State private var switching: Task<Void, Never>?
  @State private var target: String?
  @State private var choosing = false
  @State private var error: String?

  var body: some View {
    KitSection(Text("Hub Network")) {
      if facts.isJoined {
        Text("Use internet through").kitFont(.sectionHeader).padding(.horizontal, 8).padding(.top, 2)
        let rows = self.rows
        if rows.isEmpty {
          Text("None of your devices shares its internet yet. A device shares it from its own Hub Network page.")
            .kitFont(.caption).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.vertical, 4)
        }
        ForEach(rows) { device in
          row(device)
        }
        SidebarRow("All Devices") {
          RowTile(systemImage: "display")
        } trailing: {
          HStack(spacing: 4) {
            Text("\(allCount)").kitFont(.caption)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitTertiary)
          }
        }
        .action { choosing = true }
      } else {
        Text(offMessage).kitFont(.caption).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 8).padding(.vertical, 4)
      }
      if let error {
        Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
      }
    } icon: {
      Tile(systemImage: "globe", hue: .teal, size: idiom == .mac ? 24 : 28)
    } meta: {
      HStack(spacing: 4) {
        StatusDot(hue: meta.hue, isHollow: meta.hue == .gray, size: 6)
        Text(meta.text).lineLimit(1)
      }
    } accessory: {
      Toggle("Hub Network", isOn: Binding { facts.isJoined || isConnecting } set: { turn($0) })
        .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
        .disabled(facts.hubNetworkOff && !facts.isJoined)
    }
    // The title opens the Hub Network page
    .overlay(alignment: .topLeading) {
      Button { Navigator.main.open(hub, .network) } label: {
        Color.clear.frame(height: idiom == .mac ? 40 : idiom == .phone ? 52 : 48).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.trailing, 60)
      .accessibilityLabel("Open Hub Network")
    }
    .kitSheet(isPresented: $choosing) {
      UseInternetSheet()
    }
    .networkLive(facts)
  }

  private var isConnecting: Bool { switching != nil && target == nil }

  // MARK: Rows

  /// The device used last (even offline), then up to two more that share their internet now
  private var rows: [NetDevice] {
    var rows = [NetDevice]()
    if let last = facts.lastInternet { rows.append(last) }
    let available = facts.internetDevices.filter { $0.sharesInternet && $0.status != .asleep && $0.id != rows.first?.id }
    rows += available.prefix(rows.isEmpty ? 3 : 2)
    return rows
  }

  private var allCount: Int {
    let sharing = facts.internetDevices.count
    return sharing > 0 ? sharing : facts.devices.count
  }

  private func row(_ device: NetDevice) -> some View {
    let isUsing = facts.usingInternet?.id == device.id
    let isLast = facts.lastInternet?.id == device.id
    let isOffline = device.status == .asleep || !device.sharesInternet
    let line: String =
      target == device.id ? "Connecting…"
      : isUsing ? "Using its internet"
      : isLast ? (target != nil ? "Last used" : isOffline ? "Last used · offline" : "Last used · available")
      : "Available" + (device.gateway?.capability.metered == true ? " · metered" : "")
    return SidebarRow(device.name) {
      RowTile(systemImage: device.symbol)
    } trailing: {
      if target == device.id {
        Button("Cancel") { cancel() }.buttonStyle(.kit).controlSize(.small)
      } else if isUsing {
        Button("Stop") { stop() }.buttonStyle(.kit).controlSize(.small).disabled(switching != nil)
      } else {
        Button("Use") { use(device) }.buttonStyle(.kit).controlSize(.small)
          .disabled(switching != nil || isOffline)
      }
    }
    .subtitle {
      Text(line).foregroundStyle(isUsing ? AnyShapeStyle(Hue.green.text) : target == device.id ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitSecondary))
    }
  }

  // MARK: Meta

  private var meta: (text: String, hue: Hue) {
    if let target, let device = facts.devices.first(where: { $0.id == target }) {
      return ("Switching to \(device.name)…", .orange)
    }
    if isConnecting { return ("Connecting…", .orange) }
    if facts.isJoined {
      if let using = facts.usingInternet { return ("On · internet via \(using.name)", .green) }
      let count = facts.devices.count
      return ("On · \(count == 1 ? "1 device" : "\(count) devices")", .green)
    }
    if facts.hubNetworkOff { return ("Waiting for \(hub.settings.name)", .orange) }
    return ("Off", .gray)
  }

  private var offMessage: String {
    if isConnecting { return "Finding your devices…" }
    if facts.hubNetworkOff { return "Hub Network turns on when Hub is open on the Mac that runs \(hub.settings.name)." }
    return "Turn on to reach your devices and use their internet."
  }

  // MARK: Actions

  private func turn(_ on: Bool) {
    if !on, isConnecting {
      cancel()
      return
    }
    run(target: nil) { try await hub.net.setOn(on) }
  }

  private func use(_ device: NetDevice) {
    run(target: device.id) { try await hub.net.useInternet(of: device) }
  }

  private func stop() {
    run(target: nil) { try await hub.net.stopUsingInternet() }
  }

  private func cancel() {
    switching?.cancel()
    switching = nil
    target = nil
  }

  private func run(target: String?, _ action: @escaping () async throws -> Void) {
    error = nil
    self.target = target
    switching = Task {
      do {
        try await action()
      } catch is CancellationError {
      } catch {
        self.error = error.networkLine
      }
      switching = nil
      self.target = nil
    }
  }
}
#endif
