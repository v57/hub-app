//
//  OverviewPage.swift
//  Hub
//
//  A hub at a glance: what needs you first, its numbers, its service widgets, then its apps.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

struct OverviewPage: View {
  @Environment(Hub.self) private var hub
  var facts = HubFacts()
  @HubState(\.status) private var status
  @HubState(\.launcherInfo) private var launcher
  @HubState(\.hostPending) private var hostPending
  @State private var homeApps = HomeApps.main
  @State private var rates = RequestRates()
  @State private var showsMenu = false
  @State private var width: CGFloat = 1000
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        NeedsYouBanner(updates: launcher.apps.filter(\.updateAvailable))
        stats
        let widgets = facts.apps.filter { app in
          !homeApps.isHidden(app, in: hub.id) && homeApps.tile(of: app, in: hub.id) != .icon
        }
        if !widgets.isEmpty {
          KitPackedGrid(unit: idiom == .phone ? 280 : 300, spacing: KitMetrics.gutter) {
            ForEach(widgets) { app in
              WidgetCard(app: app).kitGridSpan(app.widget?.defaultSize.columns ?? 1)
            }
          }
        }
        let apps = facts.apps.filter { !homeApps.isHidden($0, in: hub.id) }
        if !apps.isEmpty {
          AppsCard(apps: apps)
        }
      }
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
    .kitPane(.content)
    .onChange(of: status.requests, initial: true) { _, requests in rates.add(requests) }
    .pageToolbar(hub.settings.name, title: {
      RichHeader(Text(hub.settings.name), size: .title) {
        HubTile(hub: hub, size: 28)
      } meta: {
        MetaLine([facts.summary, hub.settings.address.host() ?? ""])
      } accessory: {
        EmptyView()
      }
    }) {
      if hub.canViewNetwork {
        ToolGroup {
          Button("Invite", systemImage: "person.badge.plus") { Navigator.main.open(hub, .network) }
        }
      }
      Button("More", systemImage: "ellipsis") { showsMenu = true }
        .buttonStyle(.kitIcon)
        .kitMenu(isPresented: $showsMenu) { HubMenu(hub: hub) }
    }
  }

  private var stats: some View {
    let online = status.services.filter { $0.services > 0 }.count
    let waiting = hostPending.list.reduce(0) { $0 + $1.pending.count }
    let devices = facts.devices.filter { $0.approved && !$0.revoked }
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: KitMetrics.gutter), count: width < 640 ? 2 : 4), spacing: KitMetrics.gutter) {
      KitStatCard(
        "APIs", value: "\(status.services.count)", systemImage: "hexagon", hue: .blue,
        detail: MetaLine.join(["\(online) online", waiting > 0 ? "\(waiting) waiting" : ""])
      ) { Navigator.main.open(hub, .services) }
      if hub.canOpen(.devices) {
        KitStatCard(
          "Devices", value: "\(devices.count)", systemImage: "laptopcomputer", hue: .gray,
          detail: MetaLine.join(["\(devices.filter(\.online).count) online", facts.pendingDevices.isEmpty ? "" : "\(facts.pendingDevices.count) waiting"])
        ) { Navigator.main.open(hub, .devices) }
      }
      KitStatCard(
        "Requests / s", value: rates.current.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "–",
        systemImage: "waveform.path.ecg", hue: .purple,
        detail: rates.current == nil ? "\(status.requests.formatted()) in all" : nil, sparkline: rates.history
      )
      if hub.canOpen(.connections) {
        KitStatCard(
          "Connections", value: "\(facts.users.count)", systemImage: "wifi", hue: .teal,
          detail: MetaLine.join(["\(facts.users.filter { $0.services > 0 }.count) with services"])
        ) { Navigator.main.open(hub, .connections) }
      }
    }
  }
}

/// What needs the user, first: service requests, devices waiting to join, updates
struct NeedsYouBanner: View {
  let updates: [Hub.Launcher.AppInfo]
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  var facts = HubFacts()
  @HubState(\.hostPending) private var hostPending

  var body: some View {
    let requests = facts.requests
    if requests > 0 || !updates.isEmpty {
      Banner(title, message: message, systemImage: "clock", hue: .orange) {
        if idiom == .phone {
          // No room for two buttons: Review opens what waits first
          Button("Review") { Navigator.main.open(hub, requests > 0 ? (facts.pendingDevices.isEmpty ? .requests : .devices) : .launcher) }
            .buttonStyle(.kitPrimary)
        } else if updates.count == 1, let app = updates.first {
          AsyncButton(idiom == .mac ? "Update \(app.id)" : "Update") { try await hub.client.send("launcher/app/update", app.id) }
            .buttonStyle(.kit)
        } else if updates.count > 1 {
          AsyncButton("Update All") { try await hub.launcher.updateAll() }.buttonStyle(.kit)
        }
        if requests > 0 && idiom != .phone {
          Button("Review Requests") {
            Navigator.main.open(hub, facts.pendingDevices.isEmpty ? .requests : .devices)
          }
          .buttonStyle(.kitPrimary)
        }
      }
    }
  }

  private var title: String {
    let requests = facts.requests
    var parts = [String]()
    if requests > 0 { parts.append(requests == 1 ? "1 request" : "\(requests) requests") }
    if !updates.isEmpty { parts.append(updates.count == 1 ? "1 update" : "\(updates.count) updates") }
    return parts.joined(separator: " and ") + (requests + updates.count == 1 ? " needs you" : " need you")
  }

  private var message: String {
    var parts = [String]()
    let services = hostPending.list.map(\.name)
    if !services.isEmpty {
      parts.append(services.formatted(.list(type: .and)) + (services.count == 1 ? " wants" : " want") + " to post APIs")
    }
    if let device = facts.pendingDevices.first {
      parts.append("\(device.name ?? "A device") wants to join")
    }
    if updates.count == 1, let app = updates.first {
      parts.append("\(app.id) has an update")
    } else if updates.count > 1 {
      parts.append("\(updates.count) apps have updates")
    }
    return parts.joined(separator: " · ")
  }
}

/// A service's widget on a card of its own, under the app's name
private struct WidgetCard: View {
  let app: AppHeader
  @Environment(Hub.self) private var hub

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { Navigator.main.route = .app(hub.id, path: app.path) } label: {
        RichHeader(Text(app.name)) {
          AppTileIcon(app: app, size: 24)
        } meta: {
          MetaLine([app.isOnline ? "live" : "offline"])
        } accessory: {
          EmptyView()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      HubWidgetView(header: app, size: app.widget?.defaultSize ?? .x21)
        .frame(height: (app.widget?.defaultSize ?? .x21).wellHeight + 60)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.card)
  }
}

/// The hub's service apps as tiles
struct AppsCard: View {
  let apps: [AppHeader]
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RichHeader("Apps", meta: ["service apps on \(hub.settings.name)"], systemImage: "square.grid.3x3", hue: .purple)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 72 * idiom.scale), spacing: 4)], spacing: 8) {
        ForEach(apps) { app in
          Button { Navigator.main.route = .app(hub.id, path: app.path) } label: {
            Label {
              Text(app.name)
            } icon: {
              AppTileIcon(app: app, size: 36 * idiom.scale)
            }
          }
          .labelStyle(HubTileLabelStyle(badge: app.isOnline ? nil : "Offline"))
          .buttonStyle(.plain)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.card)
  }
}

/// Requests per second from the hub's running total, sampled as it changes
@MainActor @Observable
final class RequestRates {
  private var samples: [(date: Date, total: Int)] = []
  private(set) var history: [Double] = []
  var current: Double? { history.last }

  func add(_ total: Int) {
    let now = Date()
    if let last = samples.last, total >= last.total, now.timeIntervalSince(last.date) > 0.5 {
      history.append(Double(total - last.total) / now.timeIntervalSince(last.date))
      if history.count > 30 { history.removeFirst(history.count - 30) }
    }
    samples.append((now, total))
    if samples.count > 2 { samples.removeFirst(samples.count - 2) }
  }
}

extension MetaLine {
  /// Parts joined with " · ", leaving out the empty ones
  static func join(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
#endif
