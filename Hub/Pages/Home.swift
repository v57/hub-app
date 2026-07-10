//
//  Home.swift
//  Hub
//
//  Created by Linux on 02.11.25.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
import HubUI
import HubService

struct HomeView: View {
  typealias StatusBadges = Hub.StatusBadges
  enum TextFieldFocus: Hashable {
    case joinHubAddress
    case joinHubName
  }
  @FocusState var focus: TextFieldFocus?
  var isFocusing: Bool { focus == .joinHubAddress || focus == .joinHubName }
  @State var hubs = Hubs.main
  @Environment(\.colorScheme) var colorScheme
  var body: some View {
    GeometryReader { view in
      ScrollView {
        VStack(alignment: .leading) {
          HeaderSection(focus: $focus)
          ForEach(Hubs.main.list) { hub in
            HubSection().hub(hub)
          }
#if !os(tvOS)
          Text("My Apps").sectionTitle()
          HomeGrid {
            ForEach(AppServices.Service.allCases, id: \.self) { item in
              ServiceContent(item: item)
            }
          }.labelStyle(.appIcon).buttonStyle(.environment)
          Text("Join our Community").sectionTitle()
          SupportView()
#endif
        }.padding(.top).animation(.home, value: isFocusing)
          .animation(.home, value: hubs.list.count)
      }.environment(\.homeGridSpacing, HomeGridLayout.spacing(width: view.size.width - 16))
    }.buttonStyle(.plain).navigationTitle("Home")
      .scrollDismissesKeyboardImmediately()
      .scrollBounceBehavior(.basedOnSize)
      .toolbarTitleDisplayMode(.inline)
      .contentTransition(.numericText())
      .scrollIndicators(.hidden)
  }
  struct HeaderSection: View {
    @FocusState.Binding var focus: TextFieldFocus?
    @State private var copied = false
    @State var address: String = ""
    @State var merging: Hub?
    @Namespace var namespace
    var body: some View {
      HomeGrid {
#if os(tvOS)
        NavigationLink {
          ConnectView()
        } label: {
          Label("Join", systemImage: "plus")
        }.buttonStyle(.environment).labelStyle(AppIconLabelStyle())
#else
        JoinHubView(address: $address.animation(), focus: $focus)
          .gridSize(address.isEmpty ? .x21 : .x42)
#endif
        NavigationLink {
          InstallationGuide().transitionTarget(id: "guide", namespace: namespace)
        } label: {
          ZStack {
            Text("Make your own").note()
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("Learn how to host your own Hub")
              .secondary()
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          }.blockBackground().transitionSource(id: "guide", namespace: namespace)
        }.gridSize(.x21).buttonStyle(.environment)
        ForEach(Hubs.main.list) { hub in
          HubView(merging: $merging).hub(hub)
            .gridSize(.x21)
        }
#if !os(tvOS)
        Button(copied ? "Copied" : "My Key", systemImage: copied ? "checkmark.circle.fill" : "key") {
          copy()
        }.labelStyle(.appIcon).buttonStyle(.environment)
#if !os(visionOS) && !canImport(SwiftCrossUI)
        NavigationLink {
          FarmView()
            .transitionTarget(id: "farm", namespace: namespace)
        } label: {
          Label("Farm", systemImage: "tree")
        }.labelStyle(.appIcon).iconBadge(Farm.main.isRunning ? "Farming" : nil)
          .buttonStyle(.environment)
#endif
#endif
      }
    }
    func copy() {
      Task {
        withAnimation {
          copied = true
        }
        KeyChain.main.publicKey().copyToClipboard()
        try await Task.sleep(for: .seconds(3))
        withAnimation {
          copied = false
        }
      }
    }
  }
  struct HubSection: View {
    @Environment(Hub.self) var hub
    var body: some View {
      HubSectionContent(hub: hub)
    }
  }
  struct HubSectionContent: View {
    @HubState(\.statusBadges) var statusBadges
    @HubState(\.launcherInfo) var launcherInfo
    @Bindable var hub: Hub
    @State private var sheet: Sheet?
    @Namespace var namespace
    enum Sheet: Identifiable {
      var id: Sheet { self }
      case services, pending, connections, permissions, launcher, lockdown, installS3, files
    }
    var body: some View {
      Text(hub.settings.name).sectionTitle()
      HomeGrid {
        if statusBadges.services > 0 {
          Button {
            sheet = .services
          } label: {
            ServicesView()
              .transitionSource(id: Sheet.services, namespace: namespace)
          }.gridSize(.x22).buttonStyle(.environment)
        }
        Group {
          if hub.require(permissions: "hub/connections") {
            Button("Connections", systemImage: "wifi") {
              sheet = .connections
            }
          }
          if let security = statusBadges.security, security > 0 && hub.require(permissions: "hub/host/pending") {
            Button("Requests", systemImage: "clock") {
              sheet = .pending
            }.iconBadge(statusBadges.security)
          }
          if hub.require(permissions: "hub/group/list", "hub/group/names") {
            Button("Permissions", systemImage: "lock") {
              sheet = .permissions
            }
          }
          if hub.canLockdown {
            Button("Lockdown", systemImage: "key.shield") {
              sheet = .lockdown
            }
          }
          if hub.require(permissions: "launcher/status") {
            Button("Launcher", systemImage: "apple.terminal") {
              sheet = .launcher
            }
          }
          if hub.hasStorage {
            Button("Files", systemImage: "folder") {
              sheet = .files
            }
          } else if hub.canInstall {
            Button("Files", systemImage: "folder") {
              sheet = .installS3
            }
          }
          ForEach(launcherInfo.apps) { app in
            AppView(app: app)
          }
        }.labelStyle(.appIcon).buttonStyle(.environment)
        ShareServicesView().gridSize(.x22)
        if let apps = statusBadges.apps, !apps.isEmpty {
          ForEach(apps) { app in
            NavigationLink(value: app) {
              Label {
                Text(app.name)
              } icon: {
                Text(String(app.name.first ?? "A"))
              }
            }.iconBadge(app.isOnline ? nil : "Offline")
          }.labelStyle(.appIcon).buttonStyle(.environment)
        }
      }
      .navigationDestination(for: AppHeader.self) { app in
        HubAppView(header: app).hub(hub)
          .transitionTarget(id: app.id, namespace: namespace)
      }
      .navigationDestination(item: $sheet) { sheet in
        ZStack {
          switch sheet {
          case .services:
            Services()
          case .connections:
            UserConnections()
          case .pending:
            PendingListView()
          case .permissions:
            PermissionGroups()
          case .lockdown:
            LockdownView()
          case .launcher:
            LauncherView()
          case .files:
            HubFiles()
          case .installS3:
            InstallS3()
          }
        }.safeAreaPadding(.top).frame(minHeight: 400).hub(hub)
          .transitionTarget(id: sheet, namespace: namespace)
      }
    }
    struct ServicesView: View {
      @HubState(\.status) var status
      var body: some View {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(status.services.sorted(by: { $0.requests > $1.requests }).prefix(3), id: \.name) { service in
            VStack(alignment: .leading) {
              Text(service.name).foregroundStyle(.primary).truncationMode(.middle)
              HStack(spacing: 4) {
                if service.requests > 0 {
                  Label("\(service.requests)", systemImage: "checkmark")
                }
                if service.balancerType != .counter {
                  Image(systemName: service.balancerType.icon).secondary()
                }
                if let running = service.running, running > 0 {
                  Label("\(running)", systemImage: "bolt.fill")
                }
                if let pending = service.pending, pending > 0 {
                  Label("\(pending)", systemImage: "bolt.badge.clock.fill")
                }
              }.labelStyle(ItemLabelStyle())
            }.lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).secondary()
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .blockBackground()
          .bottomLabel {
            Text("Services")
          }
      }
      struct ItemLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
          HStack(spacing: 4) {
            configuration.icon
            configuration.title
          }
        }
      }
    }
    struct AppView: View {
      @Environment(Hub.self) var hub
      let app: Hub.Launcher.AppInfo
      @HubState(\.launcherStatus) var statuses
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
          return "Update"
        } else {
          return nil
        }
      }
      @State private var targetInstances: Int = 0
      @State private var showsInstances = false
      @State private var editing: Hub.Launcher.AppInfo?
      var isHub: Bool { app.id == "Hub" || app.id == "Hub Pro" || app.id == "Hub Lite" }
      var instances: Int { app.instances }
      var body: some View {
        let showsStepper = showsInstances || instances > 1
        let canUpgrade = app.id == "Hub" || app.id == "Hub Lite"
        let status = status
        let running = status?.processes?.count ?? 0
        let isRunning = app.active || running > 0
        VStack(alignment: .leading) {
          HStack(spacing: 4) {
            VStack(alignment: .leading) {
              ForEach(status?.processes?.suffix(7) ?? []) { process in
                statusText(process: process)?.transition(.blurReplace)
              }
              if status?.manyRunning == true {
                totalStatus()?.foregroundStyle(.primary)
              }
              if running > 0, let date = status?.started {
                TimelineView(.everyMinute) { timeline in
                  Text(date.shortRelative)
                }
              }
              if running == 0 {
                Text(app.active ? "Not running" : "Launch").transition(.blurReplace)
              }
            }.monospacedDigit()
            Spacer(minLength: 0)
            if !isHub {
              VStack(spacing: 10) {
                AsyncButton(isRunning ? "Stop" : "Start", systemImage: isRunning ? "pause" : "play") {
                  if isRunning {
                    try await hub.launcher.app(id: app.id).stop()
                  } else {
                    try await hub.launcher.app(id: app.id).start()
                  }
                }.contentTransition(.symbolEffect)
                if showsStepper && status?.started != nil {
                  Button("Increase", systemImage: "chevron.up") {
                    targetInstances += 1
                  }.transition(.blurReplace)
                  Button("Decrease", systemImage: "chevron.down") {
                    targetInstances -= 1
                  }.opacity(targetInstances > 1 ? 1 : 0)
                    .task(id: targetInstances) { try? await updateInstances() }
                    .transition(.blurReplace)
                }
              }.labelStyle(CircleLabelStyle())
            }
          }.secondary()
          if canUpgrade {
            UpgradeToPro()
          }
        }.overlay(alignment: .topTrailing) {
          if let installationStatus {
            Text(installationStatus).badgeStyle()
          }
        }.blockBackground().bottomLabel {
          Text(app.id)
        }.contextMenu {
          if isRunning {
            if app.instances == 1 && !isHub {
              Button("Cluster", systemImage: "list.number") {
                withAnimation {
                  showsInstances.toggle()
                }
              }
            }
            AsyncButton("Restart", systemImage: "arrow.clockwise") {
              try await hub.launcher.app(id: app.id).restart()
            }
            Button("Settings", systemImage: "gear") {
              editing = app
            }
            AsyncButton("Stop", systemImage: "stop.fill") {
              try await hub.launcher.app(id: app.id).stop()
            }
          } else {
            AsyncButton("Start", systemImage: "play.fill") {
              try await hub.launcher.app(id: app.id).start()
            }
            Button("Settings", systemImage: "gear") {
              editing = app
            }
            AsyncButton("Uninstall", systemImage: "trash.fill", role: .destructive) {
              try await hub.launcher.app(id: app.id).uninstall()
            }
          }
        }.sheet(item: $editing) {
          EditApp(app: $0).hub(hub).frame(minHeight: 300)
        }.labelStyle(.titleAndIcon).task(id: app.instances) {
          targetInstances = app.instances
        }.gridSize(showsStepper || canUpgrade ? .x22 : .x21)
      }
      func totalStatus() -> Text? {
        guard let mem = status?.totalMemory else { return nil }
        if let cpu = status?.totalCpu {
          return Text("\(Int(cpu))% \(Int(mem))MB x\(instances)")
        } else {
          return Text("\(Int(mem))MB x\(instances)")
        }
      }
      func statusText(process: Hub.Launcher.ProcessStatus) -> Text? {
        if let mem = process.memory {
          if let cpu = process.cpu {
            return Text("\(Int(cpu))% \(Int(mem))MB")
          } else {
            return Text("\(Int(mem))MB")
          }
        } else {
          return Text("Active")
        }
      }
      func updateInstances() async throws {
        guard targetInstances > 0 else { return }
        guard targetInstances != app.instances else { return }
        guard targetInstances <= 1024 else { return }
        if !showsInstances {
          showsInstances = true
        }
        try await hub.client.send("launcher/app/cluster", LauncherView.AppView.SetInstances(name: app.name, count: targetInstances))
      }
      struct CircleLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
          configuration.icon
            .symbolVariant(.circle.fill)
            .foregroundStyle(.primary, .clear)
            .font(.system(size: 34 * interfaceScale, weight: .medium))
            .hoverEffect(in: .circle)
        }
      }
      struct UpgradeToPro: View {
        @Environment(Hub.self) var hub
        @HubState(\.hostPending) private var pending
        @State private var status: Status = .upgrade
        enum Status { case upgrade, upgrading }
        var body: some View {
          AsyncButton {
            withAnimation {
              status = .upgrading
            }
            try await hub.launcher.pro(KeyChain.main.publicKey())
          } label: {
            Text(status == .upgrade ? "Upgrade to Pro" : "Upgrading").frame(maxWidth: .infinity).padding(.vertical, 4)
              .hoverEffect(in: .capsule)
          }.contentTransition(.numericText()).buttonStyle(.environment)
        }
        var item: PendingList.Item? {
          pending.list.last(where: { $0.pending.first?.starts(with: "launcher") ?? false } )
        }
      }
    }
    struct ShareServicesView: View {
      @Environment(Hub.self) var hub
      typealias Service = AppServices.Service
      var services: [Service] {
        Service.allCases.filter { service in
          service.isEnabled(hub: hub) != nil
        }
      }
      struct PublisherService {
        let service: Service
      }
      var body: some View {
        GeometryReader { view in
          let services = services
          LazyVGrid(columns: [.init(.adaptive(minimum: 36 * interfaceScale))]) {
            ForEach(services, id: \.rawValue) { service in
              ServiceToggle(service: service)
            }
          }
        }.blockBackground().bottomLabel {
          Label("Share With Hub", systemImage: "square.and.arrow.up")
        }
      }
      struct ServiceToggle: View {
        @Environment(Hub.self) var hub
        let service: Service
        var isEnabled: Bool { service.isEnabled(hub: hub) ?? false }
        var body: some View {
          Button {
            withAnimation(.smooth) {
              service.toggle(hub: hub)
            }
          } label: {
            Color.black.opacity(0.001).overlay {
              if isEnabled {
                RoundedRectangle(cornerRadius: 10)
                  .fill(.green.opacity(0.1))
                  .strokeBorder(.border)
                  .transition(.scale)
              }
            }.overlay {
              Image(systemName: service.image).fontWeight(.bold)
                .gradientBlur(radius: isEnabled ? 4 : 0)
                .frame(height: 14)
            }.aspectRatio(1, contentMode: .fit)
          }
        }
      }
    }
  }
  struct HubView: View {
    @Environment(Hub.self) var hub
    @HubState(\.statusBadges) var statusBadges
    @Binding var merging: Hub?
    var canBeMerged: Bool {
      guard let merging else { return false }
      return !merging.isMerged(to: hub) && !hub.isMerged(to: merging)
    }
    var body: some View {
      let canMerge = hub.require(permissions: "hub/merge/add")
      Menu {
        if canMerge && merging == nil {
          Button("Merge") {
            merging = hub
          }
        }
        Button("Remove") {
          Hubs.main.remove(with: hub.settings)
        }
      } label: {
        VStack(alignment: .leading) {
          HStack(spacing: 4) {
            Text(hub.settings.name)
            Spacer(minLength: 0)
            if #available(macOS 15.0, iOS 18.0, *) {
              Image(systemName: "wifi", variableValue: hub.isConnected ? 1 : 0)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeat(3), isActive: !hub.isConnected)
            }
          }.cellTitle()
          Spacer(minLength: 0)
          if hub.isConnected {
            VStack(alignment: .leading) {
              Text("\(statusBadges.services) services")
              if let security = statusBadges.security, security > 0 {
                Text("\(security) service requests").foregroundStyle(.green)
              }
            }.secondary().transition(.blurReplace)
          } else {
            Text("Connecting...").secondary().transition(.blurReplace)
          }
          if let merging, merging.id != hub.id && canMerge {
            Spacer(minLength: 0)
            if merging.isMerged(to: hub) {
              AsyncButton("Leave") {
                try await merging.unmerge(other: hub)
              }
            } else if canBeMerged {
              AsyncButton("Join") {
                try await merging.merge(other: hub)
              }
            }
          }
        }.animation(.smooth, value: hub.isConnected).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).blockBackground()
      }.buttonStyle(.environment)
    }
  }
  struct JoinHubView: View {
    let hubs = Hubs.main
    @Binding var address: String
    @State var name: String = ""
    let focus: FocusState<TextFieldFocus?>.Binding
    var url: URL? {
      guard var components = URLComponents(string: address) else { return nil }
      components.hub()
      guard let url = components.url else { return nil }
      guard !url.absoluteString.isEmpty else { return nil }
      return url
    }
    var providedName: String? { name.isEmpty ? url?.name : name }
    var body: some View {
      VStack(alignment: .leading) {
        HStack {
          Text(url?.absoluteString ?? "Join Hub").cellTitle()
          Spacer(minLength: 0)
          if let url, let providedName {
            Button {
              hubs.insert(with: Hub.Settings(name: providedName, address: url))
              self.name = ""
              self.address = ""
            } label: {
              Text("Connect")
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }.transition(.blurReplace)
          }
        }
        Spacer(minLength: 0)
        TextField("Address", text: $address).focused(focus, equals: .joinHubAddress)
          .textFieldStyle(.plain)
          .keyboard(style: .url)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          .disableHoverScale()
        if !address.isEmpty {
          TextField(url?.name ?? "Name", text: $name).focused(focus, equals: .joinHubAddress)
            .textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .transition(.blurReplace)
        }
      }.animation(.home, value: address.isEmpty).blockBackground()
    }
  }
  struct ServiceContent: View {
    let item: AppServices.Service
    @Namespace var namespace
    var body: some View {
      NavigationLink {
        AppServices.Page(service: item)
          .transitionTarget(id: item, namespace: namespace)
      } label: {
        Label(item.title, systemImage: item.image)
      }
    }
  }
}
extension View {
  func sectionTitle(padding: Bool = true) -> some View {
    modifier(SectionTitleModifier(padding: padding))
  }
  func blockBackground(_ radius: CGFloat = 16) -> some View {
    self.modifier(BlockStyle(cornerRadius: radius))
  }
  func gradientBlur(radius: CGFloat) -> some View {
    opacity(0.8).background {
      LinearGradient(colors: [.red, .orange, .green, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        .mask { blur(radius: radius) }
        .padding(-radius)
    }
  }
}
struct SectionTitleModifier: ViewModifier {
  @Environment(\.homeGridSpacing) var spacing
  let padding: Bool
  func body(content: Content) -> some View {
    content.title()
      .padding(.leading, spacing + 8)
      .padding(.top, padding ? 32 : 0)
  }
}

extension AnyTransition {
  static var home: AnyTransition {
    AnyTransition.scale
  }
}

extension Animation {
  static var home: Animation {
    .spring(response: 0.4, dampingFraction: 0.8)
  }
}
struct HomeGrid<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    HomeGridLayout {
      Group {
        content
      }.transition(.home)
    }
  }
}

struct BlockStyle: ViewModifier {
  let cornerRadius: Double
  func body(content: Content) -> some View {
    Color.clear.overlay {
      content.safeAreaPadding(8 * interfaceScale)
    }.hoverEffect()
      .padding(8 * interfaceScale)
      .contextMenuShape(RoundedRectangle(cornerRadius: cornerRadius))
  }
}

extension View {
  func cellTitle() -> some View {
    note()
  }
}

extension Date {
  var shortRelative: String {
    let offset = -Int(timeIntervalSinceNow) / 60
    guard offset > -1 else { return "future" }
    guard offset > 1 else { return "now" }
    guard offset > 60 else { return "\(offset)m" }
    return "\(offset / 60)h"
  }
}

extension URLComponents {
  mutating func hub() {
    if host == nil, !path.isEmpty || scheme != nil {
      var components = path.components(separatedBy: "/")
      if scheme != nil {
        host = scheme
        scheme = nil
        if let port = Int(components[0]) {
          self.port = port
          components.removeFirst()
        }
      } else {
        let host = components.removeFirst()
        if let port = Int(host) {
          self.port = port
          self.host = "localhost"
        } else {
          self.host = host
        }
      }
      if components.filter({ !$0.isEmpty }).count > 0 {
        path = "/" + components.joined(separator: "/")
      } else {
        path = ""
      }
    }
    // Getting scheme if needed {
    if let host, !host.isEmpty {
      if scheme == nil {
        scheme = host.isIp || host.isLocal ? "ws" : "wss"
      }
      if port == nil && scheme == "ws" {
        port = 1997
      }
    }
  }
}
extension URL {
  var pathName: String {
    return path().components(separatedBy: "/")
      .last!.components(separatedBy: "?")[0]
  }
  var name: String? {
    guard let host = host() else { return nil }
    let dots = host.components(separatedBy: ".")
    if host.isIp {
      if let port, port != 1997 {
        return "\(host):\(port)"
      } else {
        return "\(host)"
      }
    } else if let port, dots.count == 1, port != 1997 {
      return port.description // localhost:1998 -> 1998
    } else {
      var name = host.secondDomain.capitalized
      let pathName = path().components(separatedBy: "/")
        .last!.components(separatedBy: "?")[0].capitalized
      if !pathName.isEmpty {
        name += " \(pathName)"
      }
      return name // apple.com -> Apple
    }
  }
}
private extension String {
  var isIp: Bool {
    let ipv4Regex = /^((25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)$/
    let ipv6Regex = /^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$/
    return wholeMatch(of: ipv4Regex) != nil || self.wholeMatch(of: ipv6Regex) != nil
  }
  var isLocal: Bool {
    let components = components(separatedBy: ".")
    return components.count < 2 || components.last == "local" || components.last?.isEmpty ?? true
  }
  var secondDomain: String {
    let components = components(separatedBy: ".")
    guard components.count > 1 else { return self }
    return components[components.count - 2]
  }
}

#Preview {
  HomeView().test()
}
