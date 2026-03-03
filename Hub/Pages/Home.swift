//
//  Home.swift
//  Hub
//
//  Created by Linux on 02.11.25.
//

import SwiftUI
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
            HubSection().environment(hub)
          }
          Text("My Apps").sectionTitle()
          HomeGrid {
            ForEach(AppServices.Service.allCases, id: \.self) { item in
              ServiceContent(item: item)
            }
          }
          Text("Support this Project").sectionTitle()
          SupportView()
        }.padding(.top).animation(.home, value: isFocusing)
          .animation(.home, value: hubs.list.count)
          .animation(.smooth, value: view.size.width)
      }.environment(\.homeGridSpacing, HomeGridLayout.spacing(width: view.size.width - 16))
    }.buttonStyle(.plain).navigationTitle("Home")
      .scrollDismissesKeyboard(.immediately)
      .toolbarTitleDisplayMode(.inline)
      .contentTransition(.numericText())
      .scrollIndicators(.hidden)
      .background(Color.main(dark: colorScheme == .dark).ignoresSafeArea())
  }
  struct HeaderSection: View {
    @FocusState.Binding var focus: TextFieldFocus?
    @State private var copied = false
    @State var address: String = ""
    @State var merging: Hub?
    @Namespace var namespace
    var body: some View {
      HomeGrid {
        JoinHubView(address: $address.animation(), focus: $focus)
          .gridSize(address.isEmpty ? .x21 : .x42)
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
        }.gridSize(.x21)
        ForEach(Hubs.main.list) { hub in
          HubView(merging: $merging).environment(hub)
            .gridSize(.x21)
        }
        Button {
          copy()
        } label: {
          AppIcon(title: copied ? "Copied" : "My Key", systemImage: copied ? "checkmark.circle.fill" : "key")
        }
        NavigationLink {
          FarmView()
            .transitionTarget(id: "farm", namespace: namespace)
        } label: {
          AppIcon(title: "Farm", systemImage: "tree")
            .iconBadge(Farm.main.isRunning ? "Farming" : nil)
            .transitionSource(id: "farm", namespace: namespace)
        }
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
        if statusBadges.services == 0 {
          Button {
            sheet = .services
          } label: {
            ServicesView()
              .transitionSource(id: Sheet.services, namespace: namespace)
          }.gridSize(.x22)
        }
        if hub.require(permissions: "hub/connections") {
          Button {
            sheet = .connections
          } label: {
            AppIcon(title: "Connections", systemImage: "wifi")
              .iconBadge(statusBadges.connections)
              .transitionSource(id: Sheet.connections, namespace: namespace)
          }
        }
        if hub.require(permissions: "hub/host/pending") {
          Button {
            sheet = .pending
          } label: {
            AppIcon(title: "Requests", systemImage: "clock")
              .iconBadge(statusBadges.security)
              .transitionSource(id: Sheet.pending, namespace: namespace)
          }
        }
        if hub.require(permissions: "hub/group/list", "hub/group/names") {
          Button {
            sheet = .permissions
          } label: {
            AppIcon(title: "Permissions", systemImage: "lock")
              .transitionSource(id: Sheet.permissions, namespace: namespace)
          }
        }
        if hub.canLockdown {
          Button {
            sheet = .lockdown
          } label: {
            AppIcon(title: "Lockdown", systemImage: "key.shield")
              .transitionSource(id: Sheet.lockdown, namespace: namespace)
          }
        }
        if hub.require(permissions: "launcher/status") {
          Button {
            sheet = .launcher
          } label: {
            AppIcon(title: "Launcher", systemImage: "apple.terminal")
              .transitionSource(id: Sheet.launcher, namespace: namespace)
          }
        }
        if hub.hasStorage {
          Button {
            sheet = .files
          } label: {
            AppIcon(title: "Files", systemImage: "folder")
          }
        } else if hub.canInstall {
          Button {
            sheet = .installS3
          } label: {
            AppIcon(title: "Files", systemImage: "folder")
          }
        }
        ForEach(launcherInfo.apps) { app in
          AppView(app: app)
        }
        ShareServicesView().gridSize(.x22)
        if let apps = statusBadges.apps, !apps.isEmpty {
          ForEach(apps) { app in
            NavigationLink(value: app) {
              AppIcon(title: app.name, textIcon: String(app.name.first ?? "A"))
                .iconBadge(app.isOnline ? nil : "Offline", color: .red)
                .transitionSource(id: app.id, namespace: namespace)
            }
          }
        }
      }
      .navigationDestination(for: Hub.AppHeader.self) { app in
        ServiceView(header: app).environment(hub)
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
            StorageView()
          case .installS3:
            InstallS3()
          }
        }.safeAreaPadding(.top).frame(minHeight: 400)
          .environment(hub)
          .transitionTarget(id: sheet, namespace: namespace)
      }
    }
    struct ServicesView: View {
      @HubState(\.status) var status
      var body: some View {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Services")
            Spacer()
            Image(systemName: "circle.hexagongrid.fill")
          }.cellTitle()
          Spacer()
          ForEach(status.services.sorted(by: { $0.requests > $1.requests }).prefix(3), id: \.name) { service in
            VStack(alignment: .leading) {
              Text(service.name).foregroundStyle(.primary)
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
              }.labelStyle(LabelStyle())
            }
              .frame(maxWidth: .infinity, alignment: .leading).background {
              RoundedRectangle(cornerRadius: 4)
                .fill(.background).padding(.horizontal, -4).padding(.vertical, -2)
            }.secondary()
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .blockBackground()
      }
      struct LabelStyle: SwiftUI.LabelStyle {
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
      var instances: Int { app.instances }
      var body: some View {
        let showsStepper = showsInstances || instances > 1
        let canUpgrade = app.id == "Hub" || app.id == "Hub Lite"
        let status = status
        HStack(alignment: .top) {
          VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
              Text(app.id)
              Spacer()
              Image(systemName: "terminal")
            }.cellTitle()
            Spacer()
            HStack(alignment: .lastTextBaseline) {
              VStack(alignment: .leading) {
                ForEach(status?.processes?.suffix(7) ?? []) { process in
                  statusText(process: process)?.transition(.blurReplace)
                }
                if status?.manyRunning == true {
                  totalStatus()?.foregroundStyle(.primary)
                }
              }
              if (status?.processes?.count ?? 0) > 0 {
                if let date = status?.started {
                  Spacer()
                  VStack(alignment: .trailing) {
#if !os(tvOS)
                    if showsStepper {
                      HStack(spacing: 4) {
                        Text("\(targetInstances)").secondary()
                        Stepper("Instances", value: $targetInstances, in: 1...1024)
                          .labelsHidden()
                          .task(id: targetInstances) { try? await updateInstances() }
                      }.transition(.blurReplace)
                    }
#endif
                    TimelineView(.everyMinute) { timeline in
                      Text(date.shortRelative)
                    }
                  }
                }
              } else {
                Text(app.active ? "Not running" : "Stopped").transition(.blurReplace)
              }
            }.secondary()
            if canUpgrade {
              AsyncButton {
                try await hub.launcher.pro(KeyChain.main.publicKey())
              } label: {
                Text("Upgrade to Pro")
                  .frame(maxWidth: .infinity)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(.background, in: .capsule)
                  
              }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .topTrailing) {
          if let installationStatus {
            Text(installationStatus).badgeStyle()
          }
        }.blockBackground().contextMenu {
          if app.active {
            if app.instances == 1 {
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
          EditApp(app: $0).environment(hub).frame(minHeight: 300)
        }.labelStyle(.titleAndIcon).task(id: app.instances) {
          targetInstances = app.instances
        }.gridSize(showsStepper || canUpgrade ? .x22 : .x21)
      }
      func totalStatus() -> Text? {
        guard let mem = status?.totalMemory else { return nil }
        if let cpu = status?.totalCpu {
          return Text("\(Int(cpu))% \(Int(mem))MB")
        } else {
          return Text("\(Int(mem))MB")
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
    }
    struct ShareServicesView: View {
      @Environment(Hub.self) var hub
      typealias Service = AppServices.Service
      var body: some View {
        VStack(alignment: .leading) {
          HStack {
            Text("Share Services")
            Spacer()
            Image(systemName: "square.and.arrow.up")
          }.cellTitle()
          Spacer()
          LazyVGrid(columns: [.init(.adaptive(minimum: 48))]) {
            ForEach(Service.allCases, id: \.self) { service in
              if let publisher = service.servicePublisher(hub: hub) {
                ServiceToggle(publisher: publisher, service: service)
              }
            }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).blockBackground()
      }
      struct ServiceToggle: View {
        @Environment(Hub.self) var hub
        let publisher: Published<Bool>.Publisher
        let service: Service
        @State var isEnabled: Bool = false
        var body: some View {
          Button {
            withAnimation(.smooth) {
              isEnabled.toggle()
            }
            service.setService(enabled: isEnabled, hub: hub)
          } label: {
            ZStack {
              Image(systemName: service.image).fontWeight(.bold)
                .frame(height: 14)
            }.frame(maxWidth: .infinity)
              .padding(.vertical, 6)
              .background {
                RoundedRectangle(cornerRadius: 10)
                  .fill(.green.opacity(0.1))
                  .strokeBorder(.green, lineWidth: isEnabled ? 1 : 0)
              }
          }.onReceive(publisher) { isEnabled = $0 }
            
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
      VStack(alignment: .leading) {
        HStack(spacing: 4) {
          Text(hub.settings.name)
          Spacer()
          if #available(macOS 15.0, iOS 18.0, *) {
            Image(systemName: "wifi", variableValue: hub.isConnected ? 1 : 0)
              .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeat(3), isActive: !hub.isConnected)
          }
        }.cellTitle()
        Spacer()
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
          Spacer()
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
      }.animation(.smooth, value: hub.isConnected).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).blockBackground().contextMenu {
        if canMerge && merging == nil {
          Button("Merge") {
            merging = hub
          }
        }
        Button("Remove") {
          Hubs.main.remove(with: hub.settings)
        }
      }
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
          Spacer()
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
        Spacer()
        TextField("Address", text: $address).focused(focus, equals: .joinHubAddress)
          .textFieldStyle(.plain)
          .keyboard(style: .url)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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
        AppIcon(title: item.title, systemImage: item.image)
          .transitionSource(id: item, namespace: namespace)
      }
    }
  }
  struct SupportView: View {
    var body: some View {
      HomeGrid {
        Button("Discord") { }.lineLimit(1)
        Button("Patreon") { }.lineLimit(1)
        Button("Boosty") { }.lineLimit(1)
        Button("GitHub") { }.lineLimit(1)
        Button("Buy Me\na Coffee") { }.lineLimit(2)
        Button("Ko-Fi") { }.lineLimit(1)
        Button("USDT") { }.lineLimit(1)
        Button("BTC") { }.lineLimit(1)
      }.buttonStyle(LinkButtonStyle())
    }
  }
  struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.multilineTextAlignment(.center)
        .body()
        .minimumScaleFactor(0.6)
        .blockBackground()
    }
  }
  struct AppIcon<Icon: View>: View {
    let title: Text
    var badge: Text?
    var badgeColor: Color = .blue
    @ViewBuilder let icon: Icon
    var hasBadge: Bool { badge != nil }
    var body: some View {
      icon.gradientBlur(radius: hasBadge ? 4 : 1)
        .contentTransition(.symbolEffect).icon()
        .blockBackground().overlay(alignment: .top) {
          if let badge {
            badge.foregroundStyle(.white).font(.caption.bold()).padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(badgeColor, in: .capsule)
              .frame(maxWidth: .infinity, alignment: .trailing)
              .padding(.horizontal, -4)
              .offset(y: -4)
              .transition(.blurReplace)
          }
        }.overlay {
          GeometryReader { view in
            title.app().offset(y: view.size.height - 4)
              .multilineTextAlignment(.center)
              .frame(maxWidth: .infinity)
          }
        }
    }
    func iconBadge(_ value: Int?, color: Color = .blue) -> Self {
      var a = self
      if let value, value > 0 {
        a.badge = Text("\(value)")
        a.badgeColor = color
      }
      return a
    }
    func iconBadge(_ value: LocalizedStringKey?, color: Color = .blue) -> Self {
      var a = self
      if let value {
        a.badge = Text(value)
        a.badgeColor = color
      }
      return a
    }
  }
}
extension HomeView.AppIcon where Icon == Image {
  init(title: LocalizedStringKey, systemImage: String) {
    self.title = Text(title)
    self.icon = Image(systemName: systemImage)
  }
}
extension HomeView.AppIcon where Icon == Text {
  init(title: String, textIcon: String) {
    self.title = Text(title)
    self.icon = Text(textIcon)
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

struct BackgroundColor: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> Color {
    if environment.colorScheme == .dark {
      Color(red: 0.2, green: 0.2, blue: 0.24)
    } else {
      Color(hue: 0, saturation: 0, brightness: 0.92)
    }
  }
}

extension AnyTransition {
  static var home: AnyTransition {
    AnyTransition.scale
  }
}

extension Animation {
  static var home: Animation { .spring(response: 0.5, dampingFraction: 0.7) }
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
  let cornerRadius: CGFloat
  @Environment(\.colorScheme) var scheme
  func body(content: Content) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .fill(Color.main(dark: scheme == .dark))
      .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.1), radius: 10)
      .overlay { content.safeAreaPadding(8) }
      .padding(8)
      .modifier {
        #if os(macOS)
        $0
        #else
        $0.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: cornerRadius))
        #endif
      }
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

extension Color {
  static func main(dark: Bool) -> Color {
    if dark {
      Color(hue: 0.091, saturation: 0.186, brightness: 0.156)
    } else {
      Color.white
    }
  }
}

#Preview {
  NavigationStack {
    HomeView()
  }.frame(height: 800)
}
