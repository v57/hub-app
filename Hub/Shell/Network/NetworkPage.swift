//
//  NetworkPage.swift
//  Hub
//
//  A hub's network in plain words: the state and one switch on top with a map of the devices, the devices as tiles
//  (a recent few and a list once there are many), what this device shares and its internet, and Advanced folded away.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct HubNetworkPage: View {
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  var facts = NetworkFacts()
  @State private var switching: Task<Void, Never>?
  @State private var error: String?
  @State private var opened: NetDevice?
  @State private var why: NetDevice?
  @State private var adding = false
  @State private var choosingInternet = false
  @State private var sharingApp = false
#if DEBUG
  @State private var joinStage: JoinNetworkSheet.Stage?
#endif
  @State private var advancedOpen = false
  /// `hub/info`'s `host`: `app` when the Hub app runs the hub
  @State private var hubHost: String?

  /// Past this many devices the tiles become three recent ones and a list
  static let tileLimit = 24

  var body: some View {
    let devices = facts.devices
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        NetworkHero(
          state: heroState, devices: devices, error: error, isPhone: idiom == .phone,
          turn: turn, add: { adding = true }
        )
        if devices.count > Self.tileLimit {
          NetworkRecentTiles(devices: Array(facts.recent.prefix(3)), open: open)
          NetworkDeviceList(devices: facts.others, open: open, why: { why = $0 })
        } else {
          devicesSection(devices)
        }
        if facts.isJoined {
          if idiom == .phone {
            appsSection
            internetSection
          } else {
            HStack(alignment: .top, spacing: KitMetrics.gutter) {
              appsSection
              internetSection
            }
          }
        }
        advanced
      }
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
      .frame(maxWidth: 1080)
      .frame(maxWidth: .infinity)
    }
    .kitPane(.content)
    .pageToolbar("Hub Network", meta: toolbarMeta, systemImage: "globe", hue: .teal) {
      if idiom == .phone {
        Toggle("Hub Network", isOn: Binding { facts.isJoined || isSwitching } set: { turn($0) })
          .toggleStyle(.kitSwitch).labelsHidden().disabled(isSwitching || facts.hubNetworkOff)
      } else if facts.isJoined {
        Button("Add a Device", systemImage: "plus") { adding = true }.buttonStyle(.kit)
      }
    }
    .networkLive(facts)
    .task {
      struct Info: Decodable { let host: String? }
      guard !hub.isDemo else { return }
      let info: Info? = try? await hub.client.send("hub/info")
      hubHost = info?.host
    }
    .task { await hub.net.restoreIfActive() }
#if DEBUG
    // `--net-sheet device:home-nas`, `why:gaming-pc`, `add`, `internet`, `share`: an overlay at launch, for captures
    .task {
      let arguments = CommandLine.arguments
      guard let index = arguments.firstIndex(of: "--net-sheet"), index + 1 < arguments.count else { return }
      try? await Task.sleep(for: .seconds(1))
      let parts = arguments[index + 1].split(separator: ":").map(String.init)
      let device = parts.count > 1 ? facts.devices.first { $0.name == parts[1] } : nil
      switch parts[0] {
      case "device": opened = device
      case "why": why = device
      case "add": adding = true
      case "internet": choosingInternet = true
      case "share": sharingApp = true
      case "advanced": advancedOpen = true
      // `join`, `join:vpn`, `join:joining`, `join:done`, `join:used|expired|unreachable|denied|other|revoked`
      case "join":
        let kind = parts.count > 1 ? parts[1] : "confirm"
        joinStage = switch kind {
        case "confirm": .confirm
        case "vpn": .allowVPN
        case "joining": .joining
        case "done": .joined
        default: .failed(JoinFailure.demo(kind == "denied" ? "vpn" : kind))
        }
      default: break
      }
    }
    .kitSheet(isPresented: Binding { joinStage != nil } set: { if !$0 { joinStage = nil } }) {
      JoinNetworkSheet(link: "", stage: joinStage ?? .confirm)
    }
#endif
    .kitSheet(item: $opened) { device in
      NetworkDeviceSheet(device: device, why: { why = $0 })
    }
    .kitSheet(item: $why) { device in
      NetworkWhySheet(device: device)
    }
    .kitSheet(isPresented: $adding) {
      AddDeviceSheet()
    }
    .kitSheet(isPresented: $choosingInternet) {
      UseInternetSheet()
    }
    .kitSheet(isPresented: $sharingApp) {
      ShareAppSheet()
    }
  }

  private var isSwitching: Bool { switching != nil }

  private var heroState: NetworkHero.State {
    if isSwitching { return facts.isJoined ? .turningOff : .connecting }
    if facts.isJoined { return .on }
    if facts.hubNetworkOff { return .hubOff(runsOnMac: hubHost == "app" || hub.isDemo) }
    return .off
  }

  private var toolbarMeta: [String] {
    let count = facts.devices.count
    return [
      facts.isJoined ? "On" : isSwitching ? "Connecting…" : "Off",
      count == 1 ? "1 device" : "\(count) devices",
    ]
  }

  private func turn(_ on: Bool) {
    if !on, let switching {
      // Cancel while connecting
      switching.cancel()
      self.switching = nil
      return
    }
    error = nil
    switching = Task {
      do {
        try await hub.net.setOn(on)
      } catch is CancellationError {
      } catch {
        self.error = error.networkLine
      }
      switching = nil
    }
  }

  private func open(_ device: NetDevice) {
    opened = device
  }

  // MARK: Devices

  private func devicesSection(_ devices: [NetDevice]) -> some View {
    KitSection("Devices", meta: [idiom.isTouch ? "Tap one to see what you can do with it" : "Click one to see what you can do with it"], systemImage: "laptopcomputer.and.iphone", hue: .blue) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 150 : 210), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
        ForEach(devices) { device in
          NetworkDeviceTile(device: device, open: { open(device) }, why: { why = device })
        }
        if facts.isJoined && idiom != .phone {
          Button { adding = true } label: {
            Label("Add a Device", systemImage: "plus")
              .kitFont(.headline)
              .frame(maxWidth: .infinity, minHeight: 64)
              .background(RoundedRectangle(cornerRadius: KitMetrics.radiusCard).strokeBorder(.kitSeparator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
              .contentShape(RoundedRectangle(cornerRadius: KitMetrics.radiusCard))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(4)
    }
    .kitSectionStyle(.plain)
  }

  // MARK: Apps you share

  private var appsSection: some View {
    KitSection("Apps you share", meta: ["From this \(KitDevice.name)"], systemImage: "square.and.arrow.up", hue: .purple) {
      ForEach(facts.sharedApps) { app in
        SharedAppRow(app: app)
      }
      if facts.sharedApps.isEmpty {
        Text("Share an app running on this \(KitDevice.name), and your devices open it from anywhere.")
          .kitFont(.caption).fixedSize(horizontal: false, vertical: true).padding(6)
      }
      Button("Share an App…", systemImage: "plus") { sharingApp = true }
        .buttonStyle(.kit).controlSize(.small).padding(6)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: Internet

  private var internetSection: some View {
    KitSection("Internet", systemImage: "globe", hue: .indigo) {
      if hub.api.contains("network/gateway/advertise") {
        SidebarRow(
          "Let your devices use this \(KitDevice.name)’s internet",
          subtitle: "Handy when they’re away: they browse as if they were here.", systemImage: "arrow.up.forward.app", hue: .orange
        ) {
          Toggle("Let your devices use this \(KitDevice.name)’s internet", isOn: Binding {
            hub.net.isSharing
          } set: { enabled in
            Task {
              do { try await hub.net.shareInternet(enabled) } catch { self.error = error.networkLine }
            }
          })
          .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
        }
#if os(macOS)
        if hub.net.isSharing {
          SidebarRow(
            "Keep this Mac awake while sharing",
            subtitle: "So it answers when you’re away. It can sleep with the lid closed only on power.", systemImage: "sun.max", hue: .yellow
          ) {
            Toggle("Keep this Mac awake while sharing", isOn: Bindable(KeepAwake.main).isOn)
              .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
          }
        }
#endif
      }
      if hub.api.contains("network/gateway/grant") {
        SidebarRow("Use another device’s internet", subtitle: internetLine, systemImage: "globe", hue: .indigo) {
          Button("Choose…") { choosingInternet = true }.buttonStyle(.kit).controlSize(.small)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var internetLine: String {
    if let using = facts.usingInternet { return "Using \(using.name)’s internet" }
    let offering = facts.internetDevices.filter(\.sharesInternet)
    switch offering.count {
    case 0: return "Off · none of your devices shares its internet"
    case 1: return "Off · \(offering[0].name) offers its internet"
    default: return "Off · \(offering.count) devices offer theirs"
    }
  }

  // MARK: Advanced

  private var advanced: some View {
    KitSection("Advanced", meta: ["Addresses and the connection helper, for apps and terminals"], systemImage: "slider.horizontal.3", hue: .gray, isExpanded: $advancedOpen) {
      NetworkAdvanced(facts: facts)
    }
  }
}

// MARK: - Hero

/// The page's top card: where this device stands in a sentence, the one switch, and the map
struct NetworkHero: View {
  enum State: Equatable {
    case on, off, connecting, turningOff
    /// The hub's machine runs no network now; `runsOnMac` when the Hub app runs the hub there
    case hubOff(runsOnMac: Bool)
  }
  let state: State
  let devices: [NetDevice]
  var error: String?
  var isPhone = false
  let turn: (Bool) -> Void
  let add: () -> Void
  @Environment(Hub.self) private var hub

  var body: some View {
    let others = devices.filter { !$0.isThisDevice }
    let map = NetworkMap(
      hubName: hub.settings.name, thisDevice: devices.first(where: \.isThisDevice), devices: others,
      internet: others.first { $0.id == hub.net.vpn?.key }, isOn: state == .on || state == .connecting,
      isConnecting: state == .connecting, height: isPhone ? 150 : 160
    )
    Group {
      if isPhone {
        VStack(alignment: .leading, spacing: 12) {
          map
          text
        }
      } else {
        HStack(alignment: .center, spacing: 16) {
          text.frame(maxWidth: 360, alignment: .leading)
          Spacer(minLength: 0)
          map.frame(maxWidth: 440)
        }
      }
    }
    .padding(isPhone ? 12 : 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.card)
    .animation(.kit, value: state)
  }

  private var name: String { hub.settings.name }

  private var text: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 5) {
        StatusDot(hue: line.hue, isHollow: line.hue == .gray)
        Text(line.text)
      }
      .kitFont(.caption).fontWeight(.medium).foregroundStyle(line.hue == .gray ? AnyShapeStyle(.kitSecondary) : AnyShapeStyle(line.hue.text))
      Text(title).kitFont(isPhone ? .title2 : .title1).fixedSize(horizontal: false, vertical: true)
      Text(message).kitFont(.body).foregroundStyle(.kitSecondary).fixedSize(horizontal: false, vertical: true)
      if let error {
        Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        switch state {
        case .on:
          if isPhone {
            Button("Add a Device", systemImage: "plus", action: add).buttonStyle(.kitPrimary)
          } else {
            Button("Turn Off") { turn(false) }.buttonStyle(.kit)
          }
        case .off:
          Button("Turn On") { turn(true) }.buttonStyle(.kitPrimary)
        case .connecting:
          Button("Cancel") { turn(false) }.buttonStyle(.kit)
        case .turningOff:
          Button("Turn Off") {}.buttonStyle(.kit).disabled(true)
        case .hubOff:
          Button("Try Again") { Task { await hub.net.restoreIfActive() } }.buttonStyle(.kit)
        }
      }
      .padding(.top, 4)
    }
  }

  private var line: (text: String, hue: Hue) {
    switch state {
    case .on: ("On", .green)
    case .off: ("Off", .gray)
    case .connecting: ("Connecting…", .orange)
    case .turningOff: ("Turning off…", .gray)
    case .hubOff: ("Waiting for \(name)", .orange)
    }
  }

  private var title: String {
    switch state {
    case .on, .turningOff: "Your devices are connected"
    case .off: isPhone ? "Hub Network is off" : "Hub Network is off on this \(KitDevice.name)"
    case .connecting: "Connecting to \(name)…"
    case .hubOff: "\(name)’s network is off"
    }
  }

  private var message: String {
    let others = devices.filter { !$0.isThisDevice }
    let reach = others.count == 1 ? "1 device" : "\(others.count) devices"
    switch state {
    case .on, .turningOff:
      if isPhone { return "Reach \(name) and \(reach) from this \(KitDevice.name), wherever you are." }
      var text = "From this \(KitDevice.name) you can reach \(name) and \(reach), wherever you are."
      if others.count > NetworkMap.namedLimit {
        text += " \(others.filter { $0.status == .online }.count) are online now."
      } else {
        text += " They can reach this \(KitDevice.name) too."
      }
      return text
    case .off:
      return isPhone
        ? "Turn it on to reach your other devices from anywhere."
        : "Turn it on to reach your other devices from anywhere, and to let them reach this one."
    case .connecting:
      return "Finding your devices. This takes a few seconds."
    case .hubOff(let runsOnMac):
      return runsOnMac
        ? "It’s on whenever Hub is open on the Mac that runs \(name). Open Hub there, or wake that Mac."
        : "Ask \(name)’s owner to set up Hub Network on it."
    }
  }
}

// MARK: - Device tiles

/// A device as a tile: its name, a plain status, and what it shares. Opens what you can do with it.
struct NetworkDeviceTile: View {
  let device: NetDevice
  let open: () -> Void
  let why: () -> Void
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    GridCard(action: open) {
      HStack(alignment: .top, spacing: 10) {
        Tile(systemImage: device.symbol, hue: .gray, size: idiom == .phone ? 30 : 36)
        VStack(alignment: .leading, spacing: 4) {
          Text(device.name).kitFont(.headline).lineLimit(1)
          NetworkStatusLine(device: device, why: why)
          chips
        }
        Spacer(minLength: 0)
      }
      .padding(4)
    }
  }

  @ViewBuilder
  private var chips: some View {
    let shares = device.isThisDevice
      ? device.apps.isEmpty ? nil : "Shares \(device.appsLine ?? "")"
      : device.appsLine
    if shares != nil || device.sharesInternet {
      HStack(spacing: 4) {
        if device.sharesInternet {
          Chip(idiom == .phone ? "Internet" : "Shares its internet", hue: .orange)
        }
        if let shares {
          Chip(shares, hue: .blue)
        }
      }
      .controlSize(.small)
    }
  }
}

/// "● Online", "○ Asleep · seen yesterday", "● Can't reach right now · Why?"
struct NetworkStatusLine: View {
  let device: NetDevice
  var why: (() -> Void)?

  var body: some View {
    HStack(spacing: 5) {
      if device.status != .thisDevice {
        StatusDot(hue: device.hue, isHollow: device.status == .asleep || device.status == .off, size: 6)
      }
      Text(device.statusLine).lineLimit(1)
      if device.status == .cantReach, let why {
        Text("·")
        Button("Why?", action: why).buttonStyle(.plain).foregroundStyle(.kitLink)
      }
    }
    .kitFont(.caption)
  }
}

// MARK: - Many devices

/// The three devices used last, as tiles
struct NetworkRecentTiles: View {
  let devices: [NetDevice]
  let open: (NetDevice) -> Void
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    KitSection("Recent", meta: ["The ones you used last"], systemImage: "clock", hue: .blue) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 150 : 210), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
        ForEach(devices) { device in
          NetworkDeviceTile(device: device, open: { open(device) }, why: { open(device) })
        }
      }
      .padding(4)
    }
    .kitSectionStyle(.plain)
  }
}

/// Every other device as a lazy list: filters with counts, search, the ones that can't be reached first, online ones
/// by last use, asleep ones folded
struct NetworkDeviceList: View {
  let devices: [NetDevice]
  let open: (NetDevice) -> Void
  let why: (NetDevice) -> Void
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  @State private var filter = Filter.all
  @State private var search = ""
  @State private var showsAll = false

  enum Filter: Hashable { case all, online, internet, cantReach, asleep }

  /// Online rows shown before the fold
  private static let shown = 6

  var body: some View {
    let times = NetworkRecents.main.times(hub: hub)
    let matching = devices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    let unreachable = matching.filter { $0.status == .cantReach }
    let online = matching.filter { $0.status == .online }.sorted { (times[$0.id] ?? 0) > (times[$1.id] ?? 0) }
    let asleep = matching.filter { $0.status == .asleep || $0.status == .off }
    let rows: [NetDevice] = switch filter {
    case .all: unreachable + online + asleep
    case .online: online
    case .internet: matching.filter(\.sharesInternet)
    case .cantReach: unreachable
    case .asleep: asleep
    }
    let folded = filter == .all && !showsAll && search.isEmpty
    let visible = folded ? unreachable + online.prefix(Self.shown) : rows
    KitSection("Devices", meta: ["\(devices.count + 1)"], systemImage: "laptopcomputer.and.iphone", hue: .blue) {
      VStack(alignment: .leading, spacing: 8) {
        if idiom == .phone {
          KitSearchField(text: $search, prompt: "Search \(devices.count + 1) devices")
          filters(online: online.count, unreachable: unreachable.count, asleep: asleep.count, internet: matching.filter(\.sharesInternet).count)
        } else {
          HStack {
            filters(online: online.count, unreachable: unreachable.count, asleep: asleep.count, internet: matching.filter(\.sharesInternet).count)
            Spacer()
            KitSearchField(text: $search, prompt: "Search").frame(maxWidth: 200)
          }
        }
        KitLazyStack(alignment: .leading, spacing: 0) {
          ForEach(visible) { device in
            SidebarRow(device.name) {
              RowTile(systemImage: device.symbol)
            } trailing: {
              HStack(spacing: 6) {
                if device.sharesInternet { Chip("Shares internet", hue: .orange) }
                if let apps = device.appsLine { Chip(apps, hue: .blue) }
                if device.status == .cantReach {
                  Button("Why?") { why(device) }.buttonStyle(.kit).controlSize(.small)
                }
              }
              .controlSize(.small)
            }
            .subtitle { NetworkStatusLine(device: device) }
            .action { open(device) }
          }
          if folded && rows.count > visible.count {
            let more = online.count - min(online.count, Self.shown)
            SidebarRow([more > 0 ? "\(more) more online" : nil, asleep.isEmpty ? nil : "\(asleep.count) asleep"].compactMap { $0 }.joined(separator: ", ")) {
              Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.kitSecondary).frame(width: 24)
            } trailing: {
              EmptyView()
            }
            .action { withAnimation(.kit) { showsAll = true } }
          }
          if rows.isEmpty {
            Text(search.isEmpty ? "None" : "No device named “\(search)”").kitFont(.caption).padding(8)
          }
        }
      }
      .padding(6)
    }
  }

  private func filters(online: Int, unreachable: Int, asleep: Int, internet: Int) -> some View {
    KitSegmented(selection: $filter, segments: [
      KitSegment("All", value: .all),
      KitSegment("Online", value: .online, count: online),
      KitSegment(idiom == .phone ? "Internet" : "Shares internet", value: .internet, count: internet),
      KitSegment("Can’t reach", value: .cantReach, count: unreachable),
      KitSegment("Asleep", value: .asleep, count: asleep),
    ])
    .fixedSize()
  }
}

// MARK: - Apps you share

/// An app this device shares, and its menu: who can use it, disconnect everyone, stop sharing
struct SharedAppRow: View {
  let app: NetApp
  @Environment(Hub.self) private var hub
  @State private var showsMenu = false
  @State private var choosingPeople = false
  @State private var confirmsDisconnect = false
  @State private var busy = false
  @State private var error: String?
  @HubState(\.groups) private var groups

  var body: some View {
    SidebarRow(app.name, subtitle: error ?? app.line(hub: hub.settings.name), systemImage: KnownPorts.symbol(app.port), hue: .purple, status: busy ? .working : .idle) {
      Button("Who Can Use \(app.name)", systemImage: "ellipsis") { showsMenu = true }
        .buttonStyle(.kitIcon)
        .kitMenu(isPresented: $showsMenu) { menu }
    }
    .kitSheet(isPresented: $choosingPeople) {
      ChoosePeopleSheet(app: app)
    }
    .kitConfirmation(
      "Disconnect everyone from \(app.name)?", isPresented: $confirmsDisconnect,
      message: "Devices that are still allowed can connect again.", systemImage: "bolt.shield", confirm: "Disconnect"
    ) {
      run { try await hub.disconnectEveryone(from: app) }
    }
  }

  @ViewBuilder
  private var menu: some View {
    Section("Who can use \(app.name)") {
      ForEach(AccessChoice.choices(hub: hub, groups: groups.groups.map(\.name).sorted()), id: \.self) { choice in
        Toggle(isOn: Binding { app.policy.map(choice.matches) ?? false } set: { _ in
          run { try await hub.setAccess(choice.policy, of: app) }
        }) {
          Text(choice.title(hub: hub.settings.name))
        }
      }
      Button("Choose People…") { choosingPeople = true }
    }
    Divider()
    Button("Disconnect Everyone Now", systemImage: "xmark") { confirmsDisconnect = true }
    Button("Stop Sharing", systemImage: "trash", role: .destructive) {
      run { try await hub.net.share(app: nil, port: app.port ?? 0, udp: app.id.hasPrefix("udp-"), enabled: false) }
    }
  }

  private func run(_ action: @escaping () async throws -> Void) {
    busy = true
    error = nil
    Task {
      do { try await action() } catch { self.error = error.networkLine }
      busy = false
    }
  }
}

/// One of the access menu's plain names for a policy
struct AccessChoice: Hashable {
  let policy: HubNetworkPolicy

  static func choices(hub: Hub, groups: [String]) -> [AccessChoice] {
    [AccessChoice(policy: .hub())]
      + groups.filter { $0 != "owners" }.map { AccessChoice(policy: .group($0)) }
      + [AccessChoice(policy: .privateAccess())]
  }
  func title(hub: String) -> String { policy.accessName(hub: hub) }
  func matches(_ other: HubNetworkPolicy) -> Bool {
    other.mode == policy.mode && (policy.mode != .group || other.group == policy.group)
  }
}

extension KnownPorts {
  /// A shared app's symbol
  static func symbol(_ port: Int?) -> String {
    switch port.flatMap(app)?.kind {
    case "Database": "cylinder"
    case "Media server": "play.rectangle"
    case "Web preview", "Dev server", "Web server", "Website", "Secure website": "globe"
    case "Language models": "sparkles"
    case "Remote login": "terminal"
    case "Shared folders", "File sync", "File storage": "folder"
    case "Photo library": "photo"
    default: "app"
    }
  }
}

// MARK: - Advanced

/// The technical details: the connection helper (owners change it), this device's addresses and name, the hub
struct NetworkAdvanced: View {
  let facts: NetworkFacts
  @Environment(Hub.self) private var hub
  @State private var editsHelper = false
  @HubState(\.hubNetNode) private var node

  var body: some View {
    VStack(spacing: 0) {
      if hub.api.contains("hub/net/node") {
        SidebarRow("Connection helper", subtitle: helperLine, systemImage: "point.3.filled.connected.trianglepath.dotted", hue: .teal) {
          if hub.api.contains("hub/net/node/set") {
            Button("Change…") { editsHelper = true }.buttonStyle(.kit).controlSize(.small)
          }
        }
      }
      if let address = hub.net.address {
        InspectorRow("\(facts.thisName)’s address", value: address.ipv4)
        InspectorRow("IPv6", value: address.ipv6)
      }
      if let name = facts.agents.first(where: { $0.key == facts.thisDevice?.id })?.deviceAuthority {
        InspectorRow("Name", value: name)
      }
      InspectorRow("Hub", value: hub.settings.address.host() ?? hub.settings.name)
    }
    .padding(4)
    .kitSheet(isPresented: $editsHelper) {
      CoordinatorSheet(current: node?.isEmpty == false ? node : nil)
    }
  }

  private var helperLine: String {
    let host = node.flatMap { HubNetworkNodeEndpoint.host(from: $0) } ?? "Not set"
    let isDefault = node == nil || node == HubNetworkNodeEndpoint.default
    return "\(host)\(isDefault ? " (the default)" : "") · helps your devices find each other and never sees what they send"
  }
}
#endif
