import SwiftUI
import ComponentKit
import HubUI
import HubService

extension Hub {
  var canViewNetwork: Bool {
    [
      "network/resource/list",
      "network/agents/list",
      "network/status/agents",
      "network/status/connections",
      "network/diagnostics",
    ].contains(where: api.contains)
  }

  var canManageNetwork: Bool {
    api.contains("network/resource/update") && api.contains("network/resource/revoke")
  }

  func updateNetworkPolicy(resourceId: String, policy: HubNetworkPolicy) async throws {
    try await client.send(
      "network/resource/update",
      HubNetworkPolicyUpdate(resourceId: resourceId, policy: policy)
    )
  }

  func revokeNetworkResource(resourceId: String) async throws {
    try await client.send(
      "network/resource/revoke",
      HubNetworkResourceRevoke(resourceId: resourceId)
    )
  }

  func createNetworkInvitation(service: String) async throws -> String {
    struct ServiceContext: Encodable, Sendable { let service: String }
    // The channel send has no built-in timeout and its continuation ignores
    // cancellation, so a hub-server that never answers `net/invite` would hang
    // the caller forever. Race the send against a 10-second deadline with a
    // resume-once guard and fail fast.
    final class OnceBox: @unchecked Sendable {
      private let lock = NSLock()
      private var finished = false
      func complete(_ resume: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        resume()
      }
    }
    return "hub://join/" + (try await withCheckedThrowingContinuation { continuation in
      let once = OnceBox()
      let sendTask = Task {
        do {
          let code: String = try await client.send(
            "net/invite", context: ServiceContext(service: service)
          )
          once.complete { continuation.resume(returning: code) }
        } catch {
          once.complete { continuation.resume(throwing: error) }
        }
      }
      Task {
        try? await Task.sleep(for: .seconds(10))
        sendTask.cancel()
        once.complete { continuation.resume(throwing: CancellationError()) }
      }
    })
  }
}

/// The Hub Network of one hub: whether this device is on it, the devices on it and inviting more, what this device
/// shares, internet through another device, services, problems and the details, its coordinator first
struct HubNetworkView: View {
  @Environment(Hub.self) private var hub
  @HubState(\.networkResources) private var resources
  @HubState(\.networkAgents) private var agents
  @HubState(\.networkAgentStatus) private var agentStatuses
  @HubState(\.networkConnectionStatus) private var connectionStatuses
  @HubState(\.networkDiagnostics) private var diagnostics
  @HubState(\.networkLocalAgent) private var localAgent
  @HubState(\.hubNetAgents) private var hubNetAgents
  @HubState(\.hubNetNode) private var node
  @HubState(\.devices) private var hubDevices
  @HubState(\.networkGateways) private var gatewayStatuses
  @State private var membershipBusy = false
  @State private var confirmsLeaving = false
  @State private var membershipError: String?
  @State private var isCreatingInvitation = false
  @State private var invitation: NetworkInvitation?
  @State private var invitationError: String?
  @State private var portProtocol = NetworkPortProtocol.tcp
  @State private var portText = ""
  @State private var portError: String?
  @State private var gatewayBusy = false
  @State private var gatewayError: String?
  @State private var editsCoordinator = false
  /// `hub/info`'s `host`: `app` when the Hub app runs the hub
  @State private var hubHost: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        if let hubNetState {
          hubNetNotice(hubNetState)
        }
        membership
        if hub.net.isJoined {
          sharing
        }
        devices
        if hub.api.contains("network/resource/list") && !resources.isEmpty {
          services
        }
        if !problems.isEmpty {
          problemsSection
        }
        details
      }
      .padding(KitMetrics.gutter)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Hub Network")
    .toolbarTitleDisplayMode(.inline)
    .animation(.kit, value: hub.net.isJoined)
    .animation(.kit, value: membershipBusy)
    .kitSheet(item: $invitation) { invitation in
      NetworkInvitationSheet(link: invitation.link)
    }
    .kitSheet(isPresented: $editsCoordinator) {
      CoordinatorSheet(current: hasNode ? node : nil)
    }
    .kitConfirmation(
      "Leave Hub Network?", isPresented: $confirmsLeaving,
      message: "This device stops sharing its ports and internet, and your other devices can't reach it until it joins again.",
      systemImage: "network.slash", confirm: "Leave"
    ) {
      Task { await updateMembership(false) }
    }
    .task {
      await hub.net.restoreIfActive()
    }
    .task {
      struct Info: Decodable { let host: String? }
      let info: Info? = try? await hub.client.send("hub/info")
      hubHost = info?.host
    }
  }

  // MARK: Hub-net

  private enum HubNetState {
    /// No agent runs the hub's network on its machine
    case off
    /// Its agent is set up, but not connected now (the Mac asleep, hub-net stopped)
    case offline
  }

  /// Why this device can't join, while the hub's machine runs no Hub Network agent: the Hub app there, or hub-net
  /// beside a hub-server. A device elsewhere never stands in for it. `nil` while it runs, or before the hub tells.
  private var hubNetState: HubNetState? {
    guard !hub.isOnHubMachine, hub.api.contains("hub/net/local-agent"), !localAgent.updatedAt.isEmpty else { return nil }
    // This device bound itself earlier, before only the hub's machine could
    if localAgent.key == hub.key { return .off }
    switch localAgent.state {
    case .available: return nil
    case .unavailable: return .offline
    case .unbound: return .off
    }
  }

  @ViewBuilder
  private func hubNetNotice(_ state: HubNetState) -> some View {
    let name = hub.settings.name
    switch (state, hubHost == "app") {
    case (.off, true):
      Banner("Hub Network is off on \(name)", message: "Turn it on there: Run a Hub › Open Hub Network › Join Network.",
             systemImage: "network.slash", hue: .orange)
    case (.offline, true):
      Banner("\(name) is offline", message: "Open Hub on that Mac, or wake it, to bring the network back.",
             systemImage: "network.slash", hue: .orange)
    case (.offline, false):
      Banner("hub-net on \(name) is offline", message: "Start it again on the hub's machine.",
             systemImage: "network.slash", hue: .orange)
    case (.off, false):
      if hub.hasLauncher {
        Banner("\(name) has no hub-net", message: "Install it there with Hub Launcher, or open Hub on that Mac and join.",
               systemImage: "network.slash", hue: .orange) {
          Button("Open Launcher") { Navigator.main.open(hub, .launcher) }
        }
      } else {
        Banner("\(name) has no hub-net", message: "Install it on the hub's machine, or open Hub on that Mac and join.",
               systemImage: "network.slash", hue: .orange)
        KitSection("Install hub-net", meta: ["Linux"], systemImage: "terminal", hue: .gray) {
          Text("Install Hub Launcher and add hub-net with it, or build it in Terminal:").networkNote()
          Text("git clone https://github.com/v57/hub-net\ncd hub-net/agent\nmake && sudo make install")
            .kitFont(.monoSmall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.kitFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
    }
  }

  // MARK: This device

  private var membershipMeta: [String] {
    if membershipBusy { return [hub.net.isJoined ? String(localized: "Leaving…") : String(localized: "Joining…")] }
    guard hub.net.isJoined else { return [String(localized: "Not on the network")] }
    return [String(localized: "On the network")] + (hub.net.address.map { [$0.ipv4] } ?? [])
  }

  private var membership: some View {
    KitSection(
      "This Device", meta: membershipMeta, systemImage: "network", hue: .teal,
      status: membershipBusy ? .working : hub.net.isJoined ? .done : .idle
    ) {
      if hub.net.isJoined {
        if let address = hub.net.address {
          InspectorRow("Address", value: address.ipv4)
        }
      } else if hubNetState != nil {
        Text("Join once Hub Network is on at \(hub.settings.name).").networkNote()
      } else {
        Text("A private network for your devices: they reach each other directly and securely, at home or away. The first time, Hub asks to add a VPN configuration.")
          .networkNote()
      }
      if let message = membershipError ?? (hubNetState == nil ? hub.networkAppAgent.errorMessage : nil) {
        Text(message).networkError()
      }
    } accessory: {
      if hub.net.isJoined {
        Button("Leave", role: .destructive) { confirmsLeaving = true }
          .buttonStyle(.kit).controlSize(.small)
          .disabled(membershipBusy)
      } else if hubNetState == nil {
        Button("Join") { Task { await updateMembership(true) } }
          .buttonStyle(.kitPrimary).controlSize(.small)
          .disabled(membershipBusy)
      }
    }
  }

  @MainActor
  private func updateMembership(_ enabled: Bool) async {
    membershipError = nil
    membershipBusy = true
    defer { membershipBusy = false }
    do {
      try await hub.net.joinNetwork(enabled: enabled)
    } catch {
      membershipError = error.networkMessage
    }
  }

  // MARK: Coordinator

  private var canSetNode: Bool { hub.api.contains("hub/net/node/set") }

  private var hasNode: Bool { node?.isEmpty == false }

  /// The coordinator's host, `v57.dev` for `wss://v57.dev:1964`
  private var coordinatorName: String {
    guard hasNode, let node else { return String(localized: "Not set") }
    return HubNetworkNodeEndpoint.host(from: node) ?? node
  }

  // MARK: Devices

  private var memberKeys: [String] {
    Set(agents.map(\.key) + agentStatuses.map(\.key)).sorted { lhs, rhs in
      let left = (isThisDevice(lhs) ? 0 : 1, memberName(lhs).lowercased())
      let right = (isThisDevice(rhs) ? 0 : 1, memberName(rhs).lowercased())
      return left < right
    }
  }

  private func memberName(_ key: String) -> String {
    memberDevice(key)?.name ?? agents.first { $0.key == key }?.displayName ?? key.shortNetworkKey
  }

  /// The hub's device an agent runs on, which names it better than the agent does ("Hub App")
  private func memberDevice(_ key: String) -> Device? {
    guard let id = agents.first(where: { $0.key == key })?.deviceId else { return nil }
    return hubDevices.first { $0.id == id }
  }

  private func isThisDevice(_ key: String) -> Bool {
    // The hub's own agent is this device only on the hub's machine
    if hub.isOnHubMachine, let local = localAgent.key, local == key { return true }
    guard let device = agents.first(where: { $0.key == key })?.deviceId else { return false }
    return device == hub.client.device?.key.id
  }

  private var canSeeDevices: Bool {
    hub.api.contains("network/agents/list") || hub.api.contains("network/status/agents")
  }

  private var canInvite: Bool {
    hub.api.contains("hub/net/list") || hub.api.contains("hub/net/local-agent")
  }

  private var canCreateInvitation: Bool {
    hasNode
      && hub.api.contains("hub/net/list")
      && hubNetAgents.contains(where: { $0.localIp == "127.0.0.1" })
      && localAgent.canIssueInvitation
  }

  /// Why Invite is off, in words the user can act on
  private var inviteHint: String? {
    guard canInvite, !canCreateInvitation else { return nil }
    if !hasNode {
      return canSetNode
        ? String(localized: "Set a coordinator in Details to invite devices.")
        : String(localized: "An owner of this hub needs to set a coordinator before you can invite devices.")
    }
    if !hub.net.isJoined {
      return String(localized: "Join the network on this device to invite others.")
    }
    if let message = localAgent.error?.message, !message.isEmpty {
      return String(message.prefix(240))
    }
    return String(localized: "This device is still connecting to the network. Invite becomes available in a moment.")
  }

  @ViewBuilder
  private var devices: some View {
    if canSeeDevices || canInvite {
      let keys = memberKeys
      KitSection(
        "Devices", meta: [keys.count == 1 ? String(localized: "1 device") : String(localized: "\(keys.count) devices")],
        systemImage: "laptopcomputer.and.iphone", hue: .blue, status: isCreatingInvitation ? .working : .idle
      ) {
        if let invitationError {
          Text(invitationError).networkError()
        } else if let inviteHint {
          Text(inviteHint).networkNote()
        } else if keys.isEmpty {
          Text(hub.net.isJoined
               ? "Only this device so far. Invite your other devices to reach them from anywhere."
               : "No devices have joined yet.")
            .networkNote()
        }
        ForEach(keys, id: \.self) { key in
          NetworkMemberRow(
            name: memberName(key),
            platform: memberDevice(key)?.platform ?? agents.first { $0.key == key }?.platform,
            agent: agents.first { $0.key == key },
            status: agentStatuses.first { $0.key == key },
            isThisDevice: isThisDevice(key)
          )
          // Its internet, right under it: a gateway belongs to the device that offers it
          if canUseGateways, let gateway = gateway(of: key) {
            InternetGatewayRow(gateway: gateway, title: String(localized: "Internet"))
              .padding(.leading, 24)
            if hub.net.vpn?.id == gateway.id {
              GatewayFallbackRow(gateway: gateway).padding(.leading, 24)
            }
          }
        }
        // A gateway whose device isn't listed above
        if canUseGateways {
          ForEach(gateways.filter { gateway in !keys.contains { self.gateway(of: $0)?.id == gateway.id } }, id: \.id) { gateway in
            InternetGatewayRow(gateway: gateway, title: gateway.name ?? gateway.key.shortNetworkKey)
            if hub.net.vpn?.id == gateway.id {
              GatewayFallbackRow(gateway: gateway)
            }
          }
        }
      } accessory: {
        if canInvite {
          Button("Invite", systemImage: "plus") { Task { await createInvitation() } }
            .buttonStyle(.kit).controlSize(.small)
            .disabled(!canCreateInvitation || isCreatingInvitation)
        }
      }
    }
  }

  @MainActor
  private func createInvitation() async {
    isCreatingInvitation = true
    invitationError = nil
    defer { isCreatingInvitation = false }
    do {
      invitation = NetworkInvitation(link: try await hub.net.createInviteCode())
    } catch is CancellationError {
      // The hub gives up when this device's inviter isn't registered with the coordinator
      invitationError = String(localized: "The coordinator at \(coordinatorName) didn't confirm this device in time. Check that it's running and reachable, then try again.")
    } catch {
      invitationError = error.networkMessage
    }
  }

  // MARK: Sharing

  private var sharedPorts: [NetworkSharedPort] {
    hub.net.sharedTcp.map { NetworkSharedPort(protocol: .tcp, port: $0) }
      + hub.net.sharedUdp.map { NetworkSharedPort(protocol: .udp, port: $0) }
  }

  private var sharing: some View {
    KitSection(
      "Shared from This Device",
      meta: [hub.net.address.map { String(localized: "Reached at \($0.ipv4)") } ?? String(localized: "Ports your devices reach")],
      systemImage: "arrow.up.forward.circle", hue: .green, status: gatewayBusy ? .working : .idle
    ) {
      ForEach(sharedPorts.sorted()) { shared in
        SidebarRow(String(shared.port), subtitle: shared.protocol.title, systemImage: "number", hue: .green) {
          Button("Stop Sharing", systemImage: "xmark") {
            Task { await setShared(shared.port, shared.protocol, false) }
          }
          .buttonStyle(.kitIcon)
        }
      }
      HStack(spacing: 8) {
        KitSegmented(selection: $portProtocol, options: NetworkPortProtocol.allCases.map { ($0.title, $0) })
          .fixedSize()
        TextField("Port", text: $portText)
          .kitField(mono: true)
#if os(iOS)
          .keyboardType(.numberPad)
#endif
          .onSubmit { shareTypedPort() }
        Button("Share") { shareTypedPort() }
          .buttonStyle(.kit)
          .disabled(typedPort == nil)
      }
      .controlSize(.small)
      .padding(.vertical, 4)
      if let portError {
        Text(portError).networkError()
      }
      if hub.api.contains("network/gateway/advertise") && hub.api.contains("network/gateway/remove") {
        SidebarRow(
          String(localized: "Share This Device's Internet"),
          subtitle: String(localized: "Devices you allow browse through its connection"),
          systemImage: "globe", hue: .indigo
        ) {
          Toggle("Share this device's internet", isOn: Binding(
            get: { hub.net.isSharing },
            set: { enabled in Task { await updateGatewayServing(enabled) } }
          ))
          .toggleStyle(.kitSwitch).kitLabelsHidden().controlSize(.small)
          .disabled(gatewayBusy)
        }
        if let gatewayError {
          Text(gatewayError).networkError()
        }
      }
    }
  }

  private var typedPort: Int? {
    Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
  }

  private func shareTypedPort() {
    guard let port = typedPort else { return }
    Task {
      if await setShared(port, portProtocol, true) { portText = "" }
    }
  }

  @MainActor @discardableResult
  private func setShared(_ port: Int, _ networkProtocol: NetworkPortProtocol, _ enabled: Bool) async -> Bool {
    portError = nil
    do {
      switch networkProtocol {
      case .tcp: try await hub.net.shareTcp(port: port, enabled: enabled)
      case .udp: try await hub.net.shareUdp(port: port, enabled: enabled)
      }
      return true
    } catch {
      portError = error.networkMessage
      return false
    }
  }

  @MainActor
  private func updateGatewayServing(_ enabled: Bool) async {
    gatewayError = nil
    gatewayBusy = true
    defer { gatewayBusy = false }
    do {
      try await hub.net.shareNetwork(enabled: enabled)
    } catch {
      gatewayError = error.networkMessage
    }
  }

  // MARK: Internet

  /// The other devices that offer their internet. Reading the gateway list here subscribes the page to it, which
  /// `HubNet` builds its devices from.
  private var gateways: [HubNet.Device] {
    guard !gatewayStatuses.isEmpty else { return [] }
    return hub.net.devices.filter { $0.key != hub.key }.sorted { ($0.name ?? $0.key) < ($1.name ?? $1.key) }
  }

  private var canUseGateways: Bool {
    hub.api.contains("network/gateway/list") && hub.api.contains("network/gateway/grant")
  }

  /// The internet the device behind `key` offers: its own agent's gateway, or another agent's on the same device
  private func gateway(of key: String) -> HubNet.Device? {
    if let own = gateways.first(where: { $0.key == key }) { return own }
    guard let device = agents.first(where: { $0.key == key })?.deviceId else { return nil }
    return gateways.first { gateway in agents.contains { $0.key == gateway.key && $0.deviceId == device } }
  }

  // MARK: Services

  private var services: some View {
    KitSection(
      "Services",
      meta: [resources.count == 1 ? String(localized: "1 on this network") : String(localized: "\(resources.count) on this network")],
      systemImage: "point.3.connected.trianglepath.dotted", hue: .purple
    ) {
      ForEach(resources.sorted { $0.shareName < $1.shareName }, id: \.id) { resource in
        NetworkResourceRow(
          resource: resource,
          status: connectionStatuses.first { $0.resourceId == resource.resourceId }
        )
      }
    }
  }

  // MARK: Problems

  private var problems: [HubNetworkDiagnostic] {
    let visible = diagnostics.isEmpty ? connectionStatuses : diagnostics
    return visible.filter { $0.phase == .failed }
  }

  private var problemsSection: some View {
    KitSection(
      "Connection Problems",
      meta: [problems.count == 1 ? String(localized: "1 service") : String(localized: "\(problems.count) services")],
      systemImage: "exclamationmark.triangle", hue: .orange
    ) {
      ForEach(problems, id: \.id) { problem in
        SidebarRow(
          resources.first { $0.resourceId == problem.resourceId }?.shareName ?? problem.resourceId.shortNetworkKey,
          subtitle: problem.error?.message ?? String(localized: "Couldn't connect directly"),
          systemImage: "exclamationmark.triangle", hue: .orange
        ) {
          if let date = problem.updatedAt.networkDate {
            Text(date, format: .relative(presentation: .named)).networkNote()
          }
        }
      }
    }
  }

  // MARK: Details

  private var details: some View {
    KitSection("Details", systemImage: "info.circle", hue: .gray) {
      if hub.api.contains("hub/net/node") {
        InspectorRow("Coordinator") {
          HStack(spacing: 8) {
            Text(coordinatorName).foregroundStyle(hasNode ? .kitLabel : .kitSecondary)
            if canSetNode {
              Button(hasNode ? "Edit" : "Set Up") { editsCoordinator = true }
                .buttonStyle(.kit).controlSize(.small)
            }
          }
        }
      }
      InspectorRow("Hub", value: hub.settings.name, copyable: false)
      if let address = hub.net.address {
        InspectorRow("IPv4", value: address.ipv4)
        InspectorRow("IPv6", value: address.ipv6)
      }
      if canInvite {
        InspectorRow(
          "Invitations",
          value: canCreateInvitation
            ? String(localized: "Ready")
            : hub.net.isJoined ? String(localized: "Waiting for this device") : String(localized: "Join the network first"),
          copyable: false
        )
      }
    }
  }
}

/// A device that offers its internet, and Use or Stop: this device's traffic then goes through it, like a VPN
struct InternetGatewayRow: View {
  @Environment(Hub.self) private var hub
  let gateway: HubNet.Device
  var title: String
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    let inUse = hub.net.vpn?.id == gateway.id
    SidebarRow(
      title, subtitle: error ?? (hub.net.isJoined ? subtitle(inUse: inUse) : String(localized: "Join the network to use it")),
      systemImage: Device.symbol(platform: gateway.platform), hue: error != nil ? .red : inUse ? .indigo : nil,
      status: busy ? .working : .idle
    ) {
      Button(inUse ? "Stop" : "Use Internet", role: inUse ? .destructive : nil) {
        Task { await toggle(inUse) }
      }
      .buttonStyle(.kit).controlSize(.small)
      .disabled(busy || !hub.net.isJoined)
    }
  }

  private func subtitle(inUse: Bool) -> String {
    var values = [String]()
    if inUse { values.append(String(localized: "In use")) }
    if !gateway.capability.ipv6 { values.append(String(localized: "IPv4 only")) }
    if gateway.capability.metered { values.append(String(localized: "Metered")) }
    return values.isEmpty ? String(localized: "Offers its internet") : values.joined(separator: " · ")
  }

  @MainActor
  private func toggle(_ inUse: Bool) async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      if inUse { try await hub.net.disableVpn() } else { try await hub.net.vpn(through: gateway) }
    } catch {
      self.error = error.networkMessage
    }
  }
}

/// Under the device whose internet this one uses: whether to use this device's own internet while that device can't
/// be reached (asleep, away, restarting), or wait for it
struct GatewayFallbackRow: View {
  @Environment(Hub.self) private var hub
  let gateway: HubNet.Device
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    SidebarRow(
      String(localized: "Fall Back When Unreachable"),
      subtitle: error ?? (hub.net.fallsBack
        ? String(localized: "Uses this device's own internet until \(gateway.name ?? String(localized: "it")) answers")
        : String(localized: "Waits for \(gateway.name ?? String(localized: "it")) to answer")),
      systemImage: "arrow.triangle.branch", hue: error != nil ? .red : nil, status: busy ? .working : .idle
    ) {
      Toggle("Fall back when unreachable", isOn: Binding(
        get: { hub.net.fallsBack },
        set: { enabled in Task { await set(enabled) } }
      ))
      .toggleStyle(.kitSwitch).kitLabelsHidden().controlSize(.small)
      .disabled(busy)
    }
  }

  @MainActor
  private func set(_ enabled: Bool) async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await hub.net.setFallsBack(enabled)
    } catch {
      self.error = error.networkMessage
    }
  }
}

/// The coordinator the hub's invitations name: a hub-net-node every device can reach, which introduces devices to
/// each other and never carries their traffic. Hubs use v57.dev's until an owner sets another.
private struct CoordinatorSheet: View {
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @State private var address: String
  @State private var isSaving = false
  @State private var error: String?

  static let v57 = HubNetworkNodeEndpoint.default

  init(current: String?) {
    _address = State(initialValue: current ?? "")
  }

  private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    KitSheet(
      title: "Coordinator", systemImage: "point.3.filled.connected.trianglepath.dotted", hue: .teal,
      status: isSaving ? .working : error == nil ? .idle : .failed(error ?? "")
    ) {
      FormCard(footer: "Devices find each other through it. Invitations include it; no traffic passes through it.") {
        FormRow(
          "Address", help: "A hub-net-node every device can reach", systemImage: "network", error: error,
          field: TextField("wss://node.example.com:1964", text: $address)
            .kitFont(.mono).autocorrectionDisabled()
            .onChange(of: address) { error = nil }
        )
        if trimmed != Self.v57 {
          GroupRow("Use v57.dev", help: "The default, run by v57 for everyone", action: { address = Self.v57 })
        }
      }
      .kitFormHelpWhileEditing()
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
      Button("Save") { Task { await save() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(trimmed.isEmpty || isSaving)
    }
    .kitSheetDismissDisabled(isSaving)
  }

  @MainActor
  private func save() async {
    isSaving = true
    defer { isSaving = false }
    do {
      // The default is no setting at all, so the hub follows it
      try await hub.net.setNode(trimmed == Self.v57 ? nil : trimmed)
      dismiss()
    } catch {
      self.error = error.networkMessage
    }
  }
}

private extension View {
  /// A quiet line of explanation inside a section
  func networkNote() -> some View {
    kitFont(.caption).foregroundStyle(.kitSecondary).fixedSize(horizontal: false, vertical: true)
  }

  /// What went wrong, in red
  func networkError() -> some View {
    kitFont(.caption).foregroundStyle(Hue.red.text).fixedSize(horizontal: false, vertical: true)
  }
}

private struct NetworkInvitation: Identifiable {
  var id: String { link }
  let link: String
}

private enum NetworkPortProtocol: String, CaseIterable, Comparable {
  case tcp, udp
  var title: String { rawValue.uppercased() }
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct NetworkSharedPort: Identifiable, Comparable {
  var id: String { "\(`protocol`.rawValue)-\(port)" }
  let `protocol`: NetworkPortProtocol
  let port: Int
  static func < (lhs: Self, rhs: Self) -> Bool { (lhs.port, lhs.protocol) < (rhs.port, rhs.protocol) }
}

private struct NetworkMemberRow: View {
  let name: String
  let platform: String?
  let agent: HubNetworkAgent?
  let status: HubNetworkAgentStatus?
  let isThisDevice: Bool
  @State private var copied = false

  private var online: Bool { status?.available ?? agent?.online ?? true }
  private var address: String? { (status?.addresses ?? agent?.overlayAddresses ?? []).first }

  var body: some View {
    SidebarRow(name, subtitle: subtitle, systemImage: Device.symbol(platform: platform), hue: online ? .blue : .gray) {
      if let address {
        Button(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc") {
          address.copyToClipboard()
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
          }
        }
        .buttonStyle(.kitIcon)
      }
    }
    .titleAccessory {
      if isThisDevice { Chip("This device", style: .quiet) }
    }
  }

  private var subtitle: String {
    var parts = [String]()
    if !online { parts.append(String(localized: "Offline")) }
    if let address { parts.append(address) }
    return parts.isEmpty ? String(localized: "Connecting…") : parts.joined(separator: " · ")
  }
}

private struct NetworkResourceRow: View {
  @Environment(Hub.self) private var hub
  let resource: HubNetworkResource
  let status: HubNetworkConnectionStatus?
  @State private var providers = [HubNetworkProvider]()
  @State private var isEditingPolicy = false
  @State private var isConnectingDirectly = false
  @State private var peerEndpoint = ""
  @State private var connectionError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      SidebarRow(resource.shareName, subtitle: subtitle, systemImage: "point.3.connected.trianglepath.dotted", hue: .purple) {
        Menu {
          Button("Copy Address", systemImage: "doc.on.doc") {
            resource.authority.copyToClipboard()
          }
          if !providers.isEmpty {
            Button("Connect Directly…", systemImage: "network") {
              peerEndpoint = ""
              isConnectingDirectly = true
            }
          }
          if hub.canManageNetwork {
            Button("Manage Access…", systemImage: "person.badge.key") {
              isEditingPolicy = true
            }
          }
        } label: {
          Label("More", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      if let connectionError {
        Text(connectionError).kitFont(.caption).foregroundStyle(Hue.red.text)
      }
    }
    .hubStream(
      "network/providers/list",
      NetworkProviderRequest(resourceId: resource.resourceId),
      initial: [],
      to: $providers
    )
    .kitSheet(isPresented: $isEditingPolicy) {
      NetworkPolicyEditor(resource: resource)
    }
    .kitSheet(isPresented: $isConnectingDirectly) {
      KitSheet(title: "Connect Directly", meta: "The UDP endpoint of the device that provides \(resource.shareName).", systemImage: "point.3.connected.trianglepath.dotted", hue: .teal) {
        FormCard {
          FormRow("Endpoint", systemImage: "network") {
            TextField("host:port", text: $peerEndpoint).kitField(mono: true).autocorrectionDisabled().frame(maxWidth: 220)
          }
        }
      } footer: {
        Button("Cancel") { isConnectingDirectly = false }.keyboardShortcut(.cancelAction)
        Button("Connect") {
          isConnectingDirectly = false
          guard let provider = providers.first else { return }
          Task { await connect(provider: provider) }
        }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      }
    }
  }

  private var subtitle: String {
    var parts = [String]()
    parts.append(resource.authority)
    if providers.isEmpty {
      parts.append(String(localized: "Unavailable"))
    } else if let status, status.phase != .idle {
      parts.append(status.phase.label)
    } else {
      parts.append(String(localized: "Available"))
    }
    parts.append(resource.policy.label)
    return parts.joined(separator: " · ")
  }

  @MainActor
  private func connect(provider: HubNetworkProvider) async {
    connectionError = nil
    do {
      let controller = try PacketTunnelController()
      try await controller.authorizeAndInstall(
        hub: hub,
        resource: resource,
        provider: provider,
        peerEndpoint: peerEndpoint
      )
      try await controller.start()
    } catch {
      connectionError = error.networkMessage
    }
  }
}

private struct NetworkPolicyEditor: View {
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  let resource: HubNetworkResource

  @State private var mode: HubNetworkPolicyMode
  @State private var group: String
  @State private var keys: String
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var confirmsRevocation = false

  init(resource: HubNetworkResource) {
    self.resource = resource
    _mode = State(initialValue: resource.policy.mode)
    _group = State(initialValue: resource.policy.group ?? "")
    _keys = State(initialValue: resource.policy.keys?.joined(separator: "\n") ?? "")
  }

  var body: some View {
    KitSheet(title: resource.shareName, meta: "Owned by \(resource.ownerKey.shortNetworkKey)", systemImage: "lock.shield", hue: .teal, status: isSaving ? .working : .idle) {
      FormCard {
        FormRow("Who can connect", systemImage: "person.2") {
          Picker("Who can connect", selection: $mode) {
            Text("Everyone on this Hub").tag(HubNetworkPolicyMode.hub)
            Text("A permission group").tag(HubNetworkPolicyMode.group)
            Text("Selected keys").tag(HubNetworkPolicyMode.keys)
            Text("Only its owner").tag(HubNetworkPolicyMode.private)
            Text("No one").tag(HubNetworkPolicyMode.disabled)
          }
          .labelsHidden()
          .fixedSize()
        }
        if mode == .group {
          FormRow("Group", systemImage: "person.3") {
            TextField("Group name", text: $group).kitField().frame(maxWidth: 220)
          }
        } else if mode == .keys {
          FormRow("Keys", help: "One key per line", systemImage: "key") {
            TextField("Keys", text: $keys, axis: .vertical).lineLimit(4...10).kitField(mono: true).frame(maxWidth: 260)
          }
        }
      }
      FormCard(footer: "Ends every connection to \(resource.shareName). Devices that are still allowed reconnect with new access.") {
        FormRow("Disconnect Everyone Now", systemImage: "bolt.shield", hue: .red) {
          Button("Disconnect…", role: .destructive) { confirmsRevocation = true }.buttonStyle(.kit)
        }
      }
      if let errorMessage {
        Text(errorMessage).kitFont(.caption).foregroundStyle(Hue.red.text)
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") { Task { await save() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(isSaving || !isValid)
    }
    .kitSheetDismissDisabled(isSaving)
    .kitConfirmation(
      "Disconnect everyone from \(resource.shareName)?", isPresented: $confirmsRevocation,
      message: "Devices that are still allowed can connect again.", systemImage: "bolt.shield", confirm: "Disconnect"
    ) {
      Task { await revoke() }
    }
  }

  private var isValid: Bool {
    switch mode {
    case .group:
      !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .keys:
      !parsedKeys.isEmpty
    default:
      true
    }
  }

  private var parsedKeys: [String] {
    keys
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var policy: HubNetworkPolicy {
    switch mode {
    case .hub: .hub()
    case .group: .group(group.trimmingCharacters(in: .whitespacesAndNewlines))
    case .keys: .keys(Array(Set(parsedKeys)).sorted())
    case .private: .privateAccess()
    case .disabled: .disabled()
    }
  }

  @MainActor
  private func save() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await hub.updateNetworkPolicy(resourceId: resource.resourceId, policy: policy)
      dismiss()
    } catch {
      errorMessage = error.networkMessage
    }
  }

  @MainActor
  private func revoke() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await hub.revokeNetworkResource(resourceId: resource.resourceId)
      dismiss()
    } catch {
      errorMessage = error.networkMessage
    }
  }
}

/// The invitation just made: a code to scan, the link to copy or share, and how the other device uses it
private struct NetworkInvitationSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  let link: String
  @State private var copied = false

  var body: some View {
    KitSheet(title: "Invite a Device", meta: "Scan the code with the other device's camera, or send it the link.", systemImage: "person.badge.plus", hue: .teal) {
      VStack(spacing: 16) {
        KitQRCode(link, size: 200)
        Text(link)
          .kitFont(.monoSmall)
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Text("The link works once, for seven days. On the other device, open it or paste it into Join Network.")
          .kitFont(.caption)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
    } footer: {
#if !os(tvOS)
      if let url = URL(string: link) {
        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.kit)
      }
#endif
      Spacer()
      Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
        link.copyToClipboard()
        copied = true
      }
      .buttonStyle(.kit)
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }
}

private struct NetworkProviderRequest: Encodable, Hashable, Sendable {
  let resourceId: String
}

private extension HubNetworkPolicy {
  var label: String {
    switch mode {
    case .hub: String(localized: "Everyone on this Hub")
    case .group: group.map { String(localized: "Group \($0)") } ?? String(localized: "A group")
    case .keys: keys?.count == 1 ? String(localized: "1 key") : String(localized: "\(keys?.count ?? 0) keys")
    case .private: String(localized: "Only its owner")
    case .disabled: String(localized: "No one")
    }
  }
}

private extension HubNetworkConnectionPhase {
  var label: String {
    switch self {
    case .idle: String(localized: "Idle")
    case .discovering: String(localized: "Looking for a route…")
    case .connecting: String(localized: "Connecting…")
    case .connected: String(localized: "Connected directly")
    case .failed: String(localized: "Couldn't connect directly")
    }
  }
}

extension HubNetworkAgent {
  /// The id of the agent's device, from `device` or a `device:<id>` member
  var deviceId: String? {
    if let device, !device.isEmpty { return device.hasPrefix("device:") ? String(device.dropFirst(7)) : device }
    guard let member, member.hasPrefix("device:") else { return nil }
    return String(member.dropFirst(7))
  }

  var displayName: String {
    guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return key.shortNetworkKey
    }
    return name
  }
}

private extension String {
  var shortNetworkKey: String {
    guard count > 16 else { return self }
    return "\(prefix(8))…\(suffix(8))"
  }

  var networkDate: Date? {
    (try? Date(self, strategy: .iso8601)) ?? ISO8601DateFormatter.fractional.date(from: self)
  }
}

private extension ISO8601DateFormatter {
  nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

private extension Error {
  /// One readable line, short enough for a caption
  var networkMessage: String {
    if self is CancellationError { return String(localized: "This took too long. Try again.") }
    let message = localizedDescription
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return String(message.prefix(240))
  }
}

#if DEBUG
/// `HUB_OPEN_NETWORK=local` (the hub this device runs) or `=<ws address>` of an added hub: opens that hub's Hub
/// Network page at launch, to check the page on devices without taps
struct NetworkPageLaunch: View {
  let target: String
  @State private var hub: Hub?

  var body: some View {
    NavigationStack {
      if let hub {
        HubNetworkView().hub(hub)
      } else {
#if canImport(HubServer)
        if target == "local", let error = LocalHub.main.error {
          Text(error).error()
        } else {
          ProgressView("Opening \(target)…")
        }
#else
        ProgressView("Opening \(target)…")
#endif
      }
    }
    .task {
      // HUB_TUNNEL_DIAG=1: prints the extension's inviter status and diagnostics every few seconds
      guard ProcessInfo.processInfo.environment["HUB_TUNNEL_DIAG"] != nil else { return }
      var printed = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let controller = try? PacketTunnelController() else { continue }
        if let status = try? await controller.inviterStatus() {
          print("[tunnel] inviter registered=\(status.registered) listener=\(status.listenerEndpoint)")
        }
        let lines = (await controller.extensionDiagnostics() ?? "").split(separator: "\n")
        if lines.count < printed { printed = 0 }
        for line in lines.dropFirst(printed) { print("[tunnel]", line) }
        printed = lines.count
      }
    }
    .task {
#if canImport(HubServer)
      if target == "local" {
        await LocalHub.main.setEnabled(true)
      }
#endif
      while hub == nil {
        hub = Hubs.main.list.first { candidate in
#if canImport(HubServer)
          if target == "local" { return candidate.settings.address == LocalHub.main.localURL }
#endif
          return candidate.settings.address.absoluteString == target
        }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
  }
}
#endif
