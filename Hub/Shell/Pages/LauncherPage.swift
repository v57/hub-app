//
//  LauncherPage.swift
//  Hub
//
//  The apps hub-launcher runs on the hub's machine: a card each with its load and play or pause, the selected one's
//  instances, environment and secrets in the inspector, and New App.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct LauncherPage: View {
  @Environment(Hub.self) private var hub
  @HubState(\.launcherInfo) private var info
  @HubState(\.launcherStatus) private var statuses
  @AppStorage("launcher.style") private var style = ListStyle.grid
  @State private var selection: String?
  @State private var pushed: String?
  @State private var creating = false
  @State private var showsStore = false
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let updates = info.apps.filter(\.updateAvailable)
    PageWithInspector(name: "launcher", showsInspector: selected != nil) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          if info.apps.isEmpty {
            if hub.api.isEmpty { LoadingCards() } else {
              EmptyState(systemImage: "apple.terminal", title: "No Apps Yet", message: "hub-launcher runs apps on the hub’s machine and restarts them when they crash.") {
                Button("Get More…") { showsStore = true }.buttonStyle(.kit)
                Button("New App…") { creating = true }.buttonStyle(.kitPrimary)
              }
              .padding(.top, 60)
            }
          } else if style == .grid || idiom == .phone {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 150 : 240), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
              ForEach(info.apps) { app in
                LauncherCard(app: app, status: statuses.apps[app.name], isSelected: selection == app.id) { select(app.id) }
              }
            }
          } else {
            VStack(spacing: 2) {
              ForEach(info.apps) { app in
                SidebarRow(app.id, subtitle: app.statusLine(statuses.apps[app.name])) {
                  Tile(systemImage: "apple.terminal", hue: .gray, size: 20)
                } trailing: {
                  if app.updateAvailable { Chip("Update", hue: .red).controlSize(.small) }
                }
                .action { select(app.id) }
              }
            }
            .padding(4).kitSurface(.card)
          }
          if !info.apps.isEmpty {
            Text("hub-launcher on \(hub.settings.address.host() ?? hub.settings.name) · restarts apps that crash")
              .kitFont(.caption).padding(.horizontal, 4)
          }
        }
        .padding(KitMetrics.gutter)
        .padding(.bottom, 24)
      }
    } inspector: {
      if let app = selected {
        LauncherInspector(app: app, status: statuses.apps[app.name])
      }
    }
    .kitToolbar("Launcher", meta: PageMeta.parts(hub, [
      info.apps.count == 1 ? "1 app" : "\(info.apps.count) apps",
      updating.map { "Updating \($0)" } ?? "",
    ]), systemImage: HubPage.launcher.systemImage, hue: .gray) {
      if idiom != .phone {
        ListStyleSwitch(style: $style)
      }
      ToolGroup {
        if !updates.isEmpty {
          AsyncButton("Update All \(updates.count)", systemImage: "arrow.down.circle") { try await hub.launcher.updateAll() }
        }
        Button("Get More", systemImage: "bag") { showsStore = true }
        if hub.canInstall {
          Button("New App", systemImage: "plus") { creating = true }
        }
      }
    }
    .sheet(isPresented: $creating) {
      NewAppSheet().hub(hub).componentKit(accent: .hubAccent)
    }
    .sheet(isPresented: $showsStore) {
      NavigationStack { StoreView() }.hub(hub).frame(minWidth: 560, minHeight: 480).componentKit(accent: .hubAccent)
    }
    .navigationDestination(item: $pushed) { id in
      if let app = info.apps.first(where: { $0.id == id }) {
        ScrollView { LauncherInspector(app: app, status: statuses.apps[app.name]).padding(KitMetrics.gutter) }
          .kitPane(.content)
          .kitToolbar(app.id, meta: [app.statusLine(statuses.apps[app.name])], systemImage: "apple.terminal", hue: .gray) { }
          .hub(hub)
      }
    }
  }

  private var updating: String? {
    statuses.apps.values.first { $0.updating == true }?.name
  }

  private var selected: Hub.Launcher.AppInfo? {
    selection.flatMap { id in info.apps.first { $0.id == id } }
  }

  private func select(_ id: String) {
    if idiom == .phone {
      pushed = id
    } else {
      withAnimation(.kit) { selection = selection == id ? nil : id }
    }
  }
}

/// An app's card: its state, play or pause, CPU and memory, and each instance when it runs several
private struct LauncherCard: View {
  let app: Hub.Launcher.AppInfo
  let status: Hub.Launcher.AppStatus?
  let isSelected: Bool
  let action: () -> Void
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let running = (status?.processes?.count ?? 0) > 0
    GridCard(isSelected: isSelected, action: action) {
      VStack(alignment: .leading, spacing: 8) {
        RichHeader(Text(app.id)) {
          Tile(systemImage: app.isHub ? "hexagon" : "apple.terminal", hue: running ? .indigo : .gray, size: 24)
        } meta: {
          MetaLine(app.cardLine(status))
        } accessory: {
          if !app.isHub {
            AsyncButton(running ? "Stop" : "Start", systemImage: running ? "pause.fill" : "play.fill") {
              if running {
                try await hub.launcher.app(id: app.id).stop()
              } else {
                try await hub.launcher.app(id: app.id).start()
              }
            }
            .buttonStyle(.kitRound).controlSize(.small)
          }
        }
        .titleAccessory { if app.updateAvailable { Chip("Update", hue: .red, style: .solid).controlSize(.small) } }
        .padding(.horizontal, 4).padding(.top, 2)
        if idiom != .phone, running, let status {
          VStack(spacing: 6) {
            LabeledBar(label: "CPU", value: status.totalCpu.map { $0 / 100 }, hue: .blue)
            LabeledBar(label: "Memory", value: status.totalMemory.map { min($0 / 8192, 1) }, hue: .purple, text: status.totalMemory.map(Self.memory))
          }
          .padding(.horizontal, 6)
          if let processes = status.processes, processes.count > 1 {
            HStack(spacing: 4) {
              ForEach(Array(processes.prefix(4).enumerated()), id: \.offset) { index, process in
                Chip("#\(index + 1) \(Int(process.cpu ?? 0))% · \(Self.memory(process.memory ?? 0))", style: .quiet).controlSize(.small)
              }
            }
            .padding(.horizontal, 6)
          }
        } else if !running && idiom != .phone {
          Text(app.active ? "Not running" : "Stopped").kitFont(.caption).padding(.horizontal, 6)
        }
      }
    }
  }

  static func memory(_ megabytes: Double) -> String {
    megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : "\(Int(megabytes)) MB"
  }
}

extension Hub.Launcher.AppInfo {
  /// "bun · 2 instances · 3h"
  func cardLine(_ status: Hub.Launcher.AppStatus?) -> [String] {
    var parts = [String]()
    if status?.updating == true { return ["Updating"] }
    let running = status?.processes?.count ?? 0
    if running > 1 { parts.append("\(running) instances") }
    if running > 0, let started = status?.started { parts.append(started.shortRelative) }
    if running == 0 { parts.append(active ? "not running" : "stopped") }
    return parts
  }
}

/// The selected app: its instances and restarts, environment and secrets, and Save, Restart, Uninstall
private struct LauncherInspector: View {
  let app: Hub.Launcher.AppInfo
  let status: Hub.Launcher.AppStatus?
  @Environment(Hub.self) private var hub
  @State private var instances = 1
  @State private var env: [EditApp.Env] = []
  @State private var secrets: [EditApp.Env] = []
  @State private var isUninstalling = false

  var body: some View {
    let running = status?.processes?.count ?? 0
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      RichHeader(Text(app.id), size: .title) {
        Tile(systemImage: "apple.terminal", hue: .indigo, size: 28)
      } meta: {
        MetaLine(app.cardLine(status))
      } accessory: {
        EmptyView()
      }
      .titleAccessory { if app.updateAvailable { Chip("Update available", hue: .orange).controlSize(.small) } }
      .padding(.horizontal, 4)
      KitSection(running > 0 ? "Running" : "Stopped", meta: [running > 1 ? "\(running) instances" : "", status?.totalCpu.map { "\(Int($0))% CPU" } ?? ""], systemImage: running > 0 ? "play.circle" : "pause.circle", hue: running > 0 ? .blue : .gray) {
        if !app.isHub {
          InspectorRow("Instances", copyText: nil) {
            KitStepper(value: $instances, in: 1...64)
          }
        }
        InspectorRow("Restart on crash", value: app.restarts ? "On" : "Off", copyable: false)
      }
      KitSection("Environment values", meta: [env.filter { !$0.key.isEmpty }.count == 1 ? "1 value" : "\(env.filter { !$0.key.isEmpty }.count) values"], systemImage: "list.bullet.rectangle", hue: .gray) {
        ForEach($env) { $item in
          HStack(spacing: 6) {
            TextField("KEY", text: $item.key).kitField(mono: true).frame(width: 110)
            TextField("value", text: $item.value).kitField(mono: true)
          }
          .padding(.horizontal, 6)
        }
      } accessory: {
        Button("Add Value", systemImage: "plus") { env.append(.init()) }
      }
      KitSection("Secret keys", meta: ["Kept by hub-launcher, never shown again"], systemImage: "lock", hue: .orange) {
        ForEach($secrets) { $item in
          HStack(spacing: 6) {
            TextField("KEY", text: $item.key).kitField(mono: true).frame(width: 110)
            SecureField("value", text: $item.value).kitField(mono: true)
          }
          .padding(.horizontal, 6)
        }
      } accessory: {
        Button("Add Secret", systemImage: "plus") { secrets.append(.init()) }
      }
      HStack {
        AsyncButton("Save") { try await save() }.buttonStyle(.kit).disabled(settings == nil && instances == app.instances)
        if running > 0 {
          AsyncButton("Restart") { try await hub.launcher.app(id: app.id).restart() }.buttonStyle(.kit)
        }
        if !app.isHub {
          Button("Uninstall") { isUninstalling = true }.buttonStyle(.kit).foregroundStyle(Hue.red.text)
        }
      }
      .controlSize(.small)
    }
    .task(id: app) {
      instances = app.instances
      env = (app.settings?.env ?? [:]).sorted { $0.key < $1.key }.map { EditApp.Env(key: $0.key, value: $0.value) }
      secrets = (app.settings?.secrets ?? [:]).keys.sorted().map { EditApp.Env(key: $0, value: "") }
    }
    .kitDialog("Uninstall \(app.id)?", isPresented: $isUninstalling, message: "hub-launcher stops it and removes its files.", systemImage: "trash", hue: .red, confirm: "Uninstall", role: .destructive) {
      Task { try? await hub.launcher.app(id: app.id).uninstall() }
    }
  }

  /// The changed environment and the secrets typed in, or nil when nothing changed
  private var settings: Hub.Launcher.AppSettings? {
    var values = [String: String]()
    env.forEach { if !$0.key.isEmpty { values[$0.key] = $0.value } }
    var newSecrets = [String: String]()
    secrets.forEach { if !$0.key.isEmpty && !$0.value.isEmpty { newSecrets[$0.key] = $0.value } }
    let envChanged = values != (app.settings?.env ?? [:])
    guard envChanged || !newSecrets.isEmpty else { return nil }
    return Hub.Launcher.AppSettings(env: envChanged ? values : nil, secrets: newSecrets.isEmpty ? nil : newSecrets)
  }

  private func save() async throws {
    if let settings {
      try await hub.launcher.app(id: app.id).updateSettings(settings)
    }
    if instances != app.instances {
      try await hub.client.send("launcher/app/cluster", LauncherView.AppView.SetInstances(name: app.name, count: instances))
    }
  }
}

/// A new app for hub-launcher: a shell command or a Bun repository
struct NewAppSheet: View {
  enum Kind: String, CaseIterable, Hashable { case shell, bun }
  @Environment(Hub.self) private var hub
  @Environment(\.dismiss) private var dismiss
  @State private var kind = Kind.bun
  @State private var name = ""
  @State private var repo = ""
  @State private var directory = ""
  @State private var install = ""
  @State private var command = ""
  @State private var restarts = true
  @State private var error: String?

  private var defaultName: String? {
    switch kind {
    case .bun:
      let parts = repo.split(separator: "/")
      return parts.count > 1 ? String(parts.last!) : nil
    case .shell:
      return command.split(separator: " ").first.map(String.init)
    }
  }

  var body: some View {
    KitSheet(title: "New App", meta: "hub-launcher on \(hub.settings.address.host() ?? hub.settings.name) runs it and restarts it when it crashes", systemImage: "apple.terminal", hue: .gray) {
      KitSegmented(selection: $kind, options: [("Shell", Kind.shell), ("Bun", Kind.bun)])
      FormCard {
        FormRow("Name", systemImage: "textformat") {
          TextField(defaultName ?? "Weather", text: $name).kitField().frame(maxWidth: 220)
        }
        switch kind {
        case .bun:
          FormRow("Repository", help: "Cloned into ~/Hub/apps", systemImage: "shippingbox") {
            TextField("github.com/v57/hub-weather", text: $repo).kitField(mono: true).frame(maxWidth: 260)
          }
        case .shell:
          FormRow("Directory", systemImage: "folder") {
            TextField("~/apps/weather", text: $directory).kitField(mono: true).frame(maxWidth: 260)
          }
          FormRow("Install", help: "One command a line", systemImage: "arrow.down.circle") {
            TextField("bun install", text: $install, axis: .vertical).kitField(mono: true).frame(maxWidth: 260)
          }
          FormRow("Start command", systemImage: "play") {
            TextField("bun run start", text: $command).kitField(mono: true).frame(maxWidth: 260)
          }
        }
      }
      FormCard {
        FormRow("Restart on crash", systemImage: "arrow.clockwise") {
          Toggle("Restart on crash", isOn: $restarts).toggleStyle(.kitSwitch).labelsHidden()
        }
      }
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      Spacer()
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      AsyncButton("Create") {
        guard let defaultName else { return }
        let setup: Hub.Launcher.Setup = switch kind {
        case .bun: .bun(.init(repo: repo, commit: nil, command: nil))
        case .shell: .sh(.init(directory: directory.isEmpty ? nil : directory, install: install.commands(), uninstall: nil, run: command))
        }
        do {
          try await hub.launcher.create(.init(name: name.replacingEmpty(with: defaultName), active: true, restarts: restarts, setup: setup))
          dismiss()
        } catch {
          self.error = error.localizedDescription
        }
      }
      .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      .disabled(defaultName == nil)
    }
  }
}
#endif
