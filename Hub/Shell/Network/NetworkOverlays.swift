//
//  NetworkOverlays.swift
//  Hub
//
//  The Network page's overlays: what you can do with a device, why one can't be reached, whose internet to use,
//  sharing an app, and choosing who may use it.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

// MARK: - A device

/// What you can do with a device: use its internet, open its apps, copy its address
struct NetworkDeviceSheet: View {
  let device: NetDevice
  let why: (NetDevice) -> Void
  var facts = NetworkFacts()
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var busy = false
  @State private var error: String?
  @State private var copied = false
  @State private var showsFallback = false

  private var live: NetDevice { facts.devices.first { $0.id == device.id } ?? device }

  var body: some View {
    let device = live
    let isUsing = facts.usingInternet?.id == device.id
    KitSheet(title: device.name, meta: "\(device.kind) · in \(hub.settings.name)") {
      Tile(systemImage: device.symbol, hue: .gray, size: 32)
    } content: {
      if device.status == .cantReach {
        FormCard {
          FormRow("Can’t reach right now", help: "Tried \(device.unreachableSince.map { $0.formatted(.relative(presentation: .named)) } ?? "just now")", systemImage: "exclamationmark.triangle", hue: .orange) {
            Button("Why?") { why(device) }.buttonStyle(.kit)
          }
        }
      }
      if !device.isThisDevice && (device.sharesInternet || isUsing) {
        FormCard {
          FormRow(
            "Use \(device.name)’s internet", help: "Browse as if you were where \(device.name) is. Handy on public Wi-Fi.",
            systemImage: "arrow.up.forward.app", hue: .orange, error: error
          ) {
            Toggle("Use \(device.name)’s internet", isOn: Binding { isUsing } set: { use($0, device) })
              .toggleStyle(.kitSwitch).labelsHidden().disabled(busy || !facts.isJoined)
          }
          FormRow(
            "If \(device.name) stops answering",
            help: hub.net.fallsBack ? "Use this \(KitDevice.name)’s own internet until it’s back" : "Wait for it to answer",
            systemImage: "arrow.triangle.branch", hue: .gray
          ) {
            Button { showsFallback = true } label: {
              HStack(spacing: 3) {
                Text(hub.net.fallsBack ? "Use My Own" : "Wait")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
              }
            }
            .buttonStyle(.kit)
            .kitMenu(isPresented: $showsFallback) {
              FallbackChoices()
            }
          }
        }
      }
      if !device.apps.isEmpty {
        Text(device.isThisDevice ? "Apps this \(KitDevice.name) shares" : "Apps on \(device.name)").kitFont(.sectionHeader).padding(.top, 4)
        FormCard {
          ForEach(device.apps) { app in
            FormRow(app.name, help: app.line(hub: hub.settings.name), systemImage: KnownPorts.symbol(app.port), hue: .blue) {
              if !device.isThisDevice {
                Button("Open") { open(app, on: device) }.buttonStyle(.kit)
                  .disabled(device.status != .online || device.address == nil || app.port == nil)
              }
            }
          }
        }
      } else if !device.isThisDevice && !device.sharesInternet && device.status != .cantReach {
        Text("\(device.name) shares no apps yet. It can reach your devices, and they can reach it.")
          .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
      }
    } footer: {
      SheetStatus(device.statusLine, systemImage: device.status == .cantReach ? "exclamationmark.triangle" : "circle.fill", hue: device.hue)
      if let address = device.address {
        Button(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc") {
          address.copyToClipboard()
          copied = true
        }
        .buttonStyle(.kit)
      }
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  private func use(_ on: Bool, _ device: NetDevice) {
    busy = true
    error = nil
    Task {
      do {
        if on { try await hub.net.useInternet(of: device) } else { try await hub.net.stopUsingInternet() }
      } catch {
        self.error = error.networkLine
      }
      busy = false
    }
  }

  private func open(_ app: NetApp, on device: NetDevice) {
    guard let address = device.address, let port = app.port, let url = URL(string: "http://\(address):\(port)") else { return }
    NetworkRecents.main.use(device.id, hub: hub)
    openURL(url)
  }
}

/// "If it stops answering": use this device's own internet, or wait for the other one
struct FallbackChoices: View {
  @Environment(Hub.self) private var hub

  var body: some View {
    Toggle(isOn: Binding { hub.net.fallsBack } set: { _ in set(true) }) {
      Text("Use My Own")
      Text("This \(KitDevice.name)’s internet until it’s back")
    }
    Toggle(isOn: Binding { !hub.net.fallsBack } set: { _ in set(false) }) {
      Text("Wait")
      Text("Nothing goes out until it answers")
    }
  }

  private func set(_ fallsBack: Bool) {
    Task { try? await hub.net.setFallback(fallsBack) }
  }
}

extension NetDevice {
  /// "Linux server", "Mac", "iPhone"
  var kind: String {
    switch platform {
    case "macos": "Mac"
    case "ios": "iPhone"
    case "ipados": "iPad"
    case "linux": "Linux server"
    case "windows": "Windows PC"
    case "android": "Android device"
    case "tvos": "Apple TV"
    default: "Device"
    }
  }
}

// MARK: - Why?

/// Why a device can't be reached, in plain words, with Try Again and the manual way
struct NetworkWhySheet: View {
  let device: NetDevice
  var facts = NetworkFacts()
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @State private var trying = false
  @State private var connectsManually = false

  private var live: NetDevice { facts.devices.first { $0.id == device.id } ?? device }

  var body: some View {
    let device = live
    KitSheet(
      title: "Why can’t I reach \(device.name)?",
      meta: device.status == .cantReach
        ? "Can’t reach right now · tried \(device.unreachableSince.map { $0.formatted(.relative(presentation: .named)) } ?? "just now")"
        : device.statusLine,
      systemImage: "exclamationmark.triangle", hue: .orange, status: trying ? .working : .idle
    ) {
      Text(explanation(device)).kitFont(.body).fixedSize(horizontal: false, vertical: true)
    } footer: {
      if device.apps.contains(where: { $0.resource != nil }) {
        Button("Connect Manually…") { connectsManually = true }.buttonStyle(.kit)
        Spacer()
      }
      Button("Try Again") { tryAgain(device) }.buttonStyle(.kit).disabled(trying)
      Button("OK") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
    .kitSheet(isPresented: $connectsManually) {
      ConnectManuallySheet(device: device)
    }
  }

  private func explanation(_ device: NetDevice) -> String {
    switch device.status {
    case .cantReach:
      "\(device.name) is online, but the networks you’re both on won’t let Hub connect the two devices. It usually works again once either device changes Wi-Fi."
    case .asleep:
      "\(device.name) isn’t online. It answers again once it wakes up and Hub runs on it."
    case .off:
      "Hub Network is off on this \(KitDevice.name). Turn it on to reach \(device.name)."
    case .online, .thisDevice:
      "\(device.name) answers again. You can reach it."
    }
  }

  private func tryAgain(_ device: NetDevice) {
    trying = true
    Task {
      // The tunnel tries the link again on its own; a fresh look tells whether it came up
      NetworkLinks.main.mark(device.id, unreachable: false)
      try? await Task.sleep(for: .seconds(hub.isDemo ? 1.5 : 6))
      if hub.isDemo { NetworkLinks.main.mark(device.id, unreachable: true, since: device.unreachableSince ?? Date()) }
      trying = false
    }
  }
}

/// The old Connect Directly: the UDP endpoint of the device that provides one of its apps, for when the coordinator
/// can't introduce the two
private struct ConnectManuallySheet: View {
  let device: NetDevice
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @State private var endpoint = ""
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    KitSheet(title: "Connect Manually", meta: "To \(device.name), at an address you know", systemImage: "point.3.connected.trianglepath.dotted", hue: .teal, status: busy ? .working : .idle) {
      FormCard(footer: "The address and UDP port \(device.name) answers on, from its own Hub Network page or its router.") {
        FormRow("Address", systemImage: "network", error: error, field: TextField("host:port", text: $endpoint).kitFont(.mono).autocorrectionDisabled())
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Connect") { Task { await connect() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(endpoint.trimmingCharacters(in: .whitespaces).isEmpty || busy)
    }
  }

  private func connect() async {
    guard let resource = device.apps.compactMap(\.resource).first,
          let provider = NetworkProviders.main.providers[resource.resourceId]?.first else {
      error = "\(device.name) shares nothing to connect to."
      return
    }
    busy = true
    defer { busy = false }
    do {
      let controller = try PacketTunnelController()
      try await controller.authorizeAndInstall(hub: hub, resource: resource, provider: provider, peerEndpoint: endpoint.trimmingCharacters(in: .whitespaces))
      try await controller.start()
      dismiss()
    } catch {
      self.error = error.networkLine
    }
  }
}

// MARK: - Use Internet Through

/// Whose internet this device uses: its own, or one of the devices that share theirs, searchable; and what happens
/// when that device stops answering
struct UseInternetSheet: View {
  var facts = NetworkFacts()
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @State private var search = ""
  @State private var busy: String?
  @State private var error: String?
  @State private var showsFallback = false

  var body: some View {
    let sharing = facts.internetDevices
    let using = facts.usingInternet
    let total = facts.devices.count
    let shown = sharing
      .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
      .sorted { ($0.id == using?.id ? 0 : $0.sharesInternet ? 1 : 2, $0.name) < ($1.id == using?.id ? 0 : $1.sharesInternet ? 1 : 2, $1.name) }
    KitSheet(
      title: "Use Internet Through",
      meta: "\(hub.settings.name) · \(sharing.count == 1 ? "1 device shares its" : "\(sharing.count) devices share theirs")",
      systemImage: "globe", hue: .indigo, status: busy != nil ? .working : .idle
    ) {
      if total > 8 {
        KitSearchField(text: $search, prompt: "Search \(total) devices")
      }
      FormCard {
        FormRow("\(facts.thisName)’s own internet", help: "When you don’t use a device’s", systemImage: KitDevice.systemImage, hue: .gray) {
          if using == nil {
            Image(systemName: "checkmark").foregroundStyle(Hue.accent.text)
          } else {
            Button("Use") { stop() }.buttonStyle(.kit).disabled(busy != nil)
          }
        }
      }
      Text("Share their internet  \(sharing.count) of \(total)").kitFont(.sectionHeader).padding(.top, 4)
      FormCard {
        ForEach(shown) { device in
          let isUsing = device.id == using?.id
          FormRow(device.name, help: line(device, isUsing: isUsing), systemImage: device.symbol, hue: isUsing ? .indigo : .gray,
                  error: busy == nil && error != nil && device.id == lastTried ? error : nil) {
            if isUsing {
              Button("Stop") { stop() }.buttonStyle(.kit).disabled(busy != nil)
            } else {
              Button(busy == device.id ? "Connecting…" : "Use") { use(device) }
                .buttonStyle(.kit).disabled(busy != nil || !device.sharesInternet || !facts.isJoined)
            }
          }
          .opacity(device.sharesInternet || isUsing ? 1 : 0.55)
        }
        if shown.isEmpty {
          FormRow(sharing.isEmpty ? "None of your devices shares its internet yet" : "No device named “\(search)”",
                  help: sharing.isEmpty ? "A device shares it from its own Hub Network page." : nil, systemImage: "globe", hue: .gray)
        }
      }
      if let using {
        FormCard {
          FormRow(
            "If \(using.name) stops answering",
            help: hub.net.fallsBack ? "Use \(facts.thisName)’s own internet until it’s back" : "Wait for it to answer",
            systemImage: "arrow.triangle.branch", hue: .gray
          ) {
            Button { showsFallback = true } label: {
              HStack(spacing: 3) {
                Text(hub.net.fallsBack ? "Use My Own" : "Wait")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
              }
            }
            .buttonStyle(.kit)
            .kitMenu(isPresented: $showsFallback) { FallbackChoices() }
          }
        }
      }
      let others = total - 1 - sharing.count
      if others > 0 {
        Text("\(others == 1 ? "1 other device doesn’t" : "\(others) other devices don’t") share their internet. A device shares it from its own Hub Network page.")
          .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
      }
    } footer: {
      SheetStatus(using.map { "Using \($0.name)" } ?? "Using this \(KitDevice.name)’s own", systemImage: "globe", hue: .indigo, status: busy != nil ? .working : .idle)
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  @State private var lastTried: String?

  private func line(_ device: NetDevice, isUsing: Bool) -> String {
    var parts = [String]()
    if isUsing {
      parts.append("Using its internet")
    } else if device.sharesInternet && device.status != .asleep {
      parts.append("Available")
    } else {
      parts.append(device.seen.map { "Offline · seen \($0.formatted(.relative(presentation: .named)))" } ?? "Offline")
    }
    if let capability = device.gateway?.capability {
      if !capability.ipv6 { parts.append("IPv4 only") }
      if capability.metered { parts.append("metered") }
    }
    return parts.joined(separator: " · ")
  }

  private func use(_ device: NetDevice) {
    busy = device.id
    lastTried = device.id
    error = nil
    Task {
      do { try await hub.net.useInternet(of: device) } catch { self.error = error.networkLine }
      busy = nil
    }
  }

  private func stop() {
    busy = "own"
    error = nil
    Task {
      do { try await hub.net.stopUsingInternet() } catch { self.error = error.networkLine }
      busy = nil
    }
  }
}

// MARK: - Sharing

/// Share an app with the hub's devices: one running on this device, or any port; and who may use it
struct ShareAppSheet: View {
  var facts = NetworkFacts()
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom
  @State private var choice: Choice?
  @State private var name = ""
  @State private var port = ""
  @State private var udp = false
  @State private var access = AccessChoice(policy: .hub())
  @State private var showsAccess = false
  @State private var busy = false
  @State private var error: String?
  @State private var running: [ListeningApps.Found]?
  @HubState(\.groups) private var groups

  enum Choice: Hashable {
    case app(Int)
    case another
  }

  var body: some View {
    KitSheet(title: "Share an App", meta: "With your devices in \(hub.settings.name)", systemImage: "plus", hue: .accent, status: busy ? .working : .idle) {
      if running == nil {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Looking for apps on this \(KitDevice.name)…").kitFont(.caption)
        }
      } else if let running, !running.isEmpty {
        Text("Running on this \(KitDevice.name)").kitFont(.sectionHeader)
      }
      FormCard {
        ForEach(running ?? []) { app in
          appRow(app)
        }
        anotherRow
      }
      if choice == .another || idiom.isTouch && choice == nil {
        FormCard {
          FormRow("Name", systemImage: "textformat", field: TextField("Jellyfin", text: $name).autocorrectionDisabled())
          FormRow("Port", help: "The port the app listens on, on this \(KitDevice.name)", systemImage: "number", error: error, field: TextField("8096", text: $port).kitFont(.mono).autocorrectionDisabled())
          FormRow("Kind", systemImage: "arrow.left.arrow.right", hue: .gray) {
            KitSegmented(selection: $udp, options: [("TCP", false), ("UDP", true)]).fixedSize()
          }
        }
      }
      Text("Who can use it").kitFont(.sectionHeader).padding(.top, 4)
      FormCard {
        FormRow(access.title(hub: hub.settings.name), help: accessHelp, systemImage: "person.2", hue: .teal) {
          Button("Change") { showsAccess = true }
            .buttonStyle(.kit)
            .kitMenu(isPresented: $showsAccess) {
              ForEach(AccessChoice.choices(hub: hub, groups: groups.groups.map(\.name).sorted()), id: \.self) { item in
                Toggle(item.title(hub: hub.settings.name), isOn: Binding { item == access } set: { _ in access = item })
              }
            }
        }
      }
      if let error, choice != .another {
        Text(error).kitFont(.caption).foregroundStyle(Hue.red.text)
      }
    } footer: {
      if let selected {
        SheetStatus(selected.name, systemImage: KnownPorts.symbol(selected.port), hue: .blue)
      }
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
      Button("Share") { Task { await share() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(selected == nil || busy)
    }
    .kitSheetDismissDisabled(busy)
    .task { running = await ListeningApps.scan() }
  }

  private func appRow(_ app: ListeningApps.Found) -> some View {
    let isShared = facts.sharedApps.contains { $0.id == "tcp-\(app.port)" }
    return FormRow(NetworkAppNames.main.name(port: app.port), help: "\(app.app.kind) · port \(app.port)", systemImage: KnownPorts.symbol(app.port), hue: .blue) {
      if isShared {
        Chip("Shared", hue: .green)
      } else if choice == .app(app.port) {
        Image(systemName: "checkmark").foregroundStyle(Hue.accent.text)
      }
    }
    .opacity(isShared ? 0.6 : 1)
    .contentShape(Rectangle())
    .onTapGesture { if !isShared { choice = .app(app.port) } }
  }

  private var anotherRow: some View {
    FormRow("Another port…", help: "For an app that isn’t listed", systemImage: "plus", hue: .gray) {
      if choice == .another { Image(systemName: "checkmark").foregroundStyle(Hue.accent.text) }
    }
    .contentShape(Rectangle())
    .onTapGesture { choice = .another }
  }

  private var accessHelp: String {
    switch access.policy.mode {
    case .hub: "Every device and person you’ve let into \(hub.settings.name)"
    case .group: "People and devices in the \(access.policy.group ?? "") group"
    case .private: "Only your own devices"
    default: ""
    }
  }

  /// The app to share: the one picked from the list, or the typed port
  private var selected: (name: String, port: Int)? {
    switch choice {
    case .app(let port):
      return (NetworkAppNames.main.name(port: port), port)
    case .another, nil:
      guard choice == .another || idiom.isTouch, let number = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(number) else { return nil }
      let typed = name.trimmingCharacters(in: .whitespaces)
      return (typed.isEmpty ? KnownPorts.app(number)?.name ?? "Port \(number)" : typed, number)
    }
  }

  private func share() async {
    guard let selected else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await hub.net.share(app: selected.name, port: selected.port, udp: udp && choice == .another, enabled: true)
      if access.policy.mode != .hub {
        // The hub lists the share a moment after it's published
        let id = "\(udp && choice == .another ? "udp" : "tcp")-\(selected.port)"
        for _ in 0..<30 {
          if let app = facts.sharedApps.first(where: { $0.id == id }), app.resource != nil || hub.isDemo {
            try await hub.setAccess(access.policy, of: app)
            break
          }
          try await Task.sleep(for: .milliseconds(200))
        }
      }
      dismiss()
    } catch {
      self.error = error.networkLine
    }
  }
}

/// Choose who may use a shared app, from the hub's people and devices
struct ChoosePeopleSheet: View {
  let app: NetApp
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @HubState(\.users) private var users
  @State private var keys = Set<String>()
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    KitSheet(title: "Who Can Use \(app.name)", meta: "People and devices in \(hub.settings.name)", systemImage: "person.2", hue: .teal, status: busy ? .working : .idle) {
      FormCard(footer: error) {
        ForEach(users.filter { $0.key != nil }) { user in
          FormRow(user.name, help: user.group?.capitalized, systemImage: "person", hue: .gray) {
            Toggle(user.name, isOn: Binding { keys.contains(user.key ?? "") } set: { on in
              if on { keys.insert(user.key ?? "") } else { keys.remove(user.key ?? "") }
            })
            .toggleStyle(.kitSwitch).labelsHidden()
          }
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") {
        busy = true
        Task {
          do {
            try await hub.setAccess(.keys(keys.sorted()), of: app)
            dismiss()
          } catch {
            self.error = error.networkLine
          }
          busy = false
        }
      }
      .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(keys.isEmpty || busy)
    }
    .onAppear { keys = Set(app.policy?.keys ?? []) }
  }
}
#endif
