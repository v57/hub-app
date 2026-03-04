//
//  Launcher.swift
//  Hub
//
//  Created by Dmitry Kozlov on 19/2/25.
//

import SwiftUI
import HubService

struct LauncherView: View {
#if PRO
  var launcher: Launcher { .main }
#endif
  @Environment(Hub.self) var hub
  @State var editing: Hub.Launcher.AppInfo?
  var hasLauncher: Bool { hub.hasLauncher }
  @State var creating = false
  @State var openStore = false
  var body: some View {
    let task = TaskId(hub: hub.id, isConnected: hub.isConnected && hasLauncher)
    List {
      Section {
        VStack {
          Image(systemName: "apple.terminal").font(.system(size: 88))
            .gradientBlur(radius: 4)
          Text("Launcher").font(.title.bold())
          Text("""
          Installs apps
          Displays usage
          Updates apps
          Restarts on crash
          """).secondary()
            .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
      }
      LauncherCell()
      if task.isConnected {
        ListView(editing: $editing)
        Button("Get More", systemImage: "arrow.down.circle.fill") {
          withAnimation {
            openStore = true
          }
        }.buttonStyle(ActionButtonStyle())
      }
    }.toolbar {
      if task.isConnected {
        ToolbarView(creating: $creating)
      }
    }.sheet(isPresented: $creating) {
      CreateApp().padding().frame(maxWidth: 300).page()
    }.sheet(item: $editing) {
      EditApp(app: $0).environment(hub).frame(minHeight: 300).page()
    }.navigationDestination(isPresented: $openStore) {
      StoreView().environment(hub).page()
    }.task(id: task) {
#if PRO
      if task.isConnected {
        launcher.status = .running
      } else {
        switch Launcher.main.status {
        case .running, .stopping:
          launcher.status = .offline
        default: break
        }
      }
#endif
    }
  }
  struct ListView: View {
    @Binding var editing: Hub.Launcher.AppInfo?
    @HubState(\.launcherInfo) var info
    var body: some View {
      ForEach(info.apps) { app in
        AppView(app: app, editing: $editing)
      }
    }
  }
  struct ToolbarView: View {
    @Environment(Hub.self) var hub
    @Binding var creating: Bool
    @HubState(\.launcherInfo) var info
    @HubState(\.launcherStatus) var status
    var updateAvailable: Bool {
      info.apps.contains(where: { $0.updateAvailable })
    }
    var isUpdating: Bool {
      status.apps.values.contains(where: { $0.updating ?? false })
    }
    var isCheckingForUpdates: Bool {
      status.apps.values.contains(where: { $0.checkingForUpdates ?? false })
    }
    var body: some View {
      if updateAvailable && !isUpdating {
        AsyncButton("Update All", systemImage: "arrow.down.circle") {
          try await hub.launcher.updateAll()
        }
      }
      if !isCheckingForUpdates {
        AsyncButton("Check for Updates", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
          try await hub.launcher.checkForUpdates()
        }
      }
      Button("Create", systemImage: "plus") {
        creating.toggle()
      }.labelStyle(.iconOnly)
    }
  }
  struct TaskId: Hashable {
    var hub: Hub.ID
    var isConnected: Bool
  }
  struct LauncherCell: View {
#if PRO
    var launcher: Launcher { .main }
    var status: Launcher.Status {
      launcher.status
    }
    @State var updatesAvailable = false
    @Environment(Hub.self) var hub
#endif
    var body: some View {
      HStack {
        VStack(alignment: .leading) {
          Text("Launcher")
          #if PRO
          Text(status.statusText).secondary()
          #endif
        }
        Spacer()
#if PRO
        HStack {
          if updatesAvailable {
            AsyncButton("Update", systemImage: "square.and.arrow.down.fill") {
              await launcher.update()
              updatesAvailable = false
            }.help("Update")
          }
          if let buttonIcon = status.buttonIcon, let buttonTitle = status.buttonTitle {
            AsyncButton(buttonTitle, systemImage: buttonIcon) {
              switch status {
              case .notInstalled, .installationFailed, .bunInstallationFailed, .downloadFailed:
                await Launcher.main.install()
              case .installed, .offline:
                await Launcher.main.launch()
              case .running:
                await Launcher.main.stop(hub: hub)
              case .status, .stopping: break
              }
            }.help(buttonTitle)
          }
        }.labelStyle(.iconOnly).buttonStyle(.borderless)
#endif
      }.contextMenu {
#if PRO
        if updatesAvailable {
          AsyncButton("Update") {
            await launcher.update()
            updatesAvailable = false
          }
        } else {
          AsyncButton("Check for Updates") {
            updatesAvailable = await launcher.checkForUpdates()
          }
        }
#endif
      }
    }
  }
  struct AppView: View {
    @Environment(Hub.self) var hub
    var status: Hub.Launcher.AppStatus? {
      statuses.apps[app.name]
    }
    var installationStatus: LocalizedStringKey? {
      guard let status else { return nil }
      if status.updating ?? false {
        return "Updating"
      } else if status.checkingForUpdates ?? false {
        return "Checking for updates"
      } else if app.updateAvailable {
        return "Update available"
      } else {
        return nil
      }
    }
    @HubState(\.launcherStatus) var statuses
    let app: Hub.Launcher.AppInfo
    @Binding var editing: Hub.Launcher.AppInfo?
    @State var instances: Int = 0
    @State var showsInstances = false
    var body: some View {
      let status = status
      HStack(alignment: .top) {
        VStack(alignment: .leading) {
          HStack {
            Text(app.id)
            if let installationStatus {
              Text(installationStatus).badgeStyle()
            }
          }
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
              ForEach(status?.processes ?? []) { process in
                statusText(process: process)
              }
            }
            if (status?.processes?.count ?? 0) > 0 {
              if let date = status?.started {
                Text(date, style: .relative)
              }
            }
          }.secondary()
        }
        Spacer()
        if showsInstances || app.instances > 1 {
          HStack {
            Text("\(instances)").secondary()
#if !os(tvOS)
            Stepper("Instances", value: $instances)
              .labelsHidden()
              .task(id: instances) { try? await updateInstances() }
#endif
          }
        }
        if app.id == "Hub Lite" {
          AsyncButton("Upgrade to Pro") {
            try await hub.launcher.pro(KeyChain.main.publicKey())
          }.buttonStyle(.borderedProminent)
        }
      }.contextMenu {
        if app.active {
          if app.instances == 1 {
            Button("Cluster", systemImage: "list.number") {
              showsInstances = true
            }
          }
          Button("Edit", systemImage: "gear") {
            editing = app
          }
          AsyncButton("Stop", systemImage: "stop.fill") {
            try await hub.launcher.app(id: app.id).stop()
          }
        } else {
          AsyncButton("Start", systemImage: "play.fill") {
            try await hub.launcher.app(id: app.id).start()
          }
          AsyncButton("Uninstall", systemImage: "trash.fill", role: .destructive) {
            try await hub.launcher.app(id: app.id).uninstall()
          }
        }
      }.labelStyle(.titleAndIcon).task(id: app.instances) {
        instances = app.instances
      }
    }
    func statusText(process: Hub.Launcher.ProcessStatus) -> Text? {
      if let mem = process.memory {
        if let cpu = process.cpu {
          return Text("\(Int(cpu))% \(mem.description)MB")
        } else {
          return Text("\(mem.description)MB")
        }
      } else {
        return Text("Not running")
      }
    }
    func updateInstances() async throws {
      guard instances > 0 else { return }
      guard instances != app.instances else { return }
      guard instances <= 1024 else { return }
      if !showsInstances {
        showsInstances = true
      }
      try await hub.client.send("launcher/app/cluster", SetInstances(name: app.name, count: instances))
    }
    struct SetInstances: Encodable {
      let name: String
      let count: Int
    }
  }
}
#if PRO
extension Launcher.Status {
  var statusText: LocalizedStringKey {
    switch self {
    case .notInstalled: "Not installed"
    case .downloadFailed: "Failed to download the project"
    case .bunInstallationFailed: "Failed to install Bun"
    case .installationFailed: "Installation failed"
    case .installed: "Installed"
    case .status(let s): s
    case .stopping: "Stopping"
    case .offline: "Offline"
    case .running: "Running"
    }
  }
  var buttonTitle: LocalizedStringKey? {
    switch self {
    case .notInstalled: "Install"
    case .installed, .offline: "Launch"
    case .running: "Stop"
    case .stopping: "Stopping"
    default: nil
    }
  }
  var buttonIcon: String? {
    switch self {
    case .notInstalled: "plus"
    case .installed, .offline: "play.fill"
    case .running: "pause.fill"
    default: nil
    }
  }
}
#endif

#Preview {
  LauncherView().test()
}
