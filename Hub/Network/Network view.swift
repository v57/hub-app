#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
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
    // cancellation, so a hub-pro that never answers `net/invite` would hang
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
/// shares, internet through another device, services, problems and, folded away, the technical details
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
  @State private var gatewayUseError: String?
  @State private var nodeInput = ""
  @State private var nodeError: String?
  @State private var isEditingNode = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        status
        if needsNodeSetup {
          nodeSetup
        }
        devices
        if hub.net.isJoined {
          sharing
        }
        if showsInternet {
          internet
        }
        if hub.api.contains("network/resource/list") && !resources.isEmpty {
          services
        }
        if !problems.isEmpty {
          problemsSection
        }
        details
      }
      .padding()
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Hub Network")
    .toolbarTitleDisplayMode(.inline)
    .animation(.home, value: hub.net.isJoined)
    .animation(.home, value: membershipBusy)
    .sheet(item: $invitation) { invitation in
      NetworkInvitationSheet(link: invitation.link)
    }
    .confirmationDialog("Leave Hub Network?", isPresented: $confirmsLeaving, titleVisibility: .visible) {
      Button("Leave", role: .destructive) {
        Task { await updateMembership(false) }
      }
    } message: {
      Text("This device stops sharing its ports and internet, and your other devices can't reach it until it joins again.")
    }
    .task {
      await hub.net.restoreIfActive()
    }
  }

  // MARK: Status

  private var status: some View {
    VStack(spacing: 16) {
      Placeholder(
        image: "network",
        title: "Hub Network",
        description: hub.net.isJoined
          ? nil
          : "A private network for your devices. They reach each other directly and securely, at home or away.",
        isEnabled: hub.net.isJoined
      ) {
        if hub.net.isJoined {
          Label("Connected to \(hub.settings.name)", systemImage: "checkmark.circle")
          if let address = hub.net.address {
            Label("This device is \(address.ipv4)", systemImage: "location")
              .textSelection(.enabled)
          }
        }
      }
      if membershipBusy {
        ProgressView(hub.net.isJoined ? "Leaving…" : "Joining…")
          .controlSize(.small)
          .frame(height: 32)
      } else if hub.net.isJoined {
        Button("Leave Network") { confirmsLeaving = true }
          .buttonStyle(.bordered)
      } else {
        Button {
          Task { await updateMembership(true) }
        } label: {
          Text("Join Network").frame(minWidth: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Text("The first time, Hub asks to add a VPN configuration.")
          .secondary()
      }
      if let message = membershipError ?? hub.networkAppAgent.errorMessage {
        Text(message).error().multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
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

  // MARK: Node

  private var canSetNode: Bool { hub.api.contains("hub/net/node/set") }

  private var hasNode: Bool { node?.isEmpty == false }

  /// Invitations carry the hub's node and there is no default one, so an owner sets it before anything else
  private var needsNodeSetup: Bool {
    hub.api.contains("hub/net/node") && canSetNode && !hasNode
  }

  private var nodeSetup: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader(
        "Set up the network",
        "Devices find each other through a node, a small server they can all reach. Invitations include it."
      )
      nodeField
    }
  }

  private var nodeField: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField(node ?? "node.example.com:7000", text: $nodeInput)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
#if os(iOS)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
#endif
          .onSubmit { Task { await saveNode() } }
        AsyncButton("Save") { await saveNode() }
          .buttonStyle(.bordered)
          .disabled(nodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if let nodeError {
        Text(nodeError).error()
      }
    }
  }

  @MainActor
  private func saveNode() async {
    guard !nodeInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    nodeError = nil
    do {
      try await hub.net.setNode(nodeInput)
      nodeInput = ""
      isEditingNode = false
    } catch {
      nodeError = error.networkMessage
    }
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
    if let local = localAgent.key, local == key { return true }
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
      return canSetNode ? "Set up the network above to invite devices." : "An owner of this Hub needs to set up the network before you can invite devices."
    }
    if !hub.net.isJoined {
      return "Join the network on this device to invite others."
    }
    if let message = localAgent.error?.message, !message.isEmpty {
      return String(message.prefix(240))
    }
    return "This device is still connecting to the network. Invite becomes available in a moment."
  }

  @ViewBuilder
  private var devices: some View {
    if canSeeDevices || canInvite {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          sectionHeader("Devices", nil)
          Spacer()
          if canInvite {
            Button {
              Task { await createInvitation() }
            } label: {
              if isCreatingInvitation {
                ProgressView().controlSize(.small)
              } else {
                Label("Invite", systemImage: "plus")
              }
            }
            .buttonStyle(.bordered)
            .disabled(!canCreateInvitation || isCreatingInvitation)
          }
        }
        let keys = memberKeys
        if let invitationError {
          Text(invitationError).error()
        } else if let inviteHint {
          Text(inviteHint).secondary()
        } else if keys.isEmpty {
          Text(hub.net.isJoined
               ? "Only this device so far. Invite your other devices to reach them from anywhere."
               : "No devices have joined yet.")
            .secondary()
        }
        if !keys.isEmpty {
          NetworkCard {
            ForEach(Array(keys.enumerated()), id: \.element) { index, key in
              if index > 0 { Divider() }
              NetworkMemberRow(
                name: memberName(key),
                platform: memberDevice(key)?.platform ?? agents.first { $0.key == key }?.platform,
                agent: agents.first { $0.key == key },
                status: agentStatuses.first { $0.key == key },
                isThisDevice: isThisDevice(key)
              )
            }
          }
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
      // The hub gives up when this device's inviter isn't registered with the node
      invitationError = String(localized: "The node at \(node ?? "") didn't confirm this device in time. Check that the node is running and reachable, then try again.")
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
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader(
        "Shared from this device",
        hub.net.address.map { "Your other devices reach these ports at \($0.ipv4)." }
          ?? "Your other devices reach these ports over the network."
      )
      NetworkCard {
        ForEach(sharedPorts.sorted()) { shared in
          HStack {
            Text(shared.protocol.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              .frame(width: 36, alignment: .leading)
            Text(String(shared.port)).monospacedDigit()
            Spacer()
            Button("Stop Sharing", systemImage: "xmark.circle.fill") {
              Task { await setShared(shared.port, shared.protocol, false) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
          }
          Divider()
        }
        HStack {
          Picker("Protocol", selection: $portProtocol) {
            ForEach(NetworkPortProtocol.allCases, id: \.self) { value in
              Text(value.title).tag(value)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          TextField("Port", text: $portText)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
#if os(iOS)
            .keyboardType(.numberPad)
#endif
            .onSubmit { shareTypedPort() }
          Button("Share") { shareTypedPort() }
            .buttonStyle(.bordered)
            .disabled(typedPort == nil)
        }
        if let portError {
          Text(portError).error()
        }
      }
      if hub.api.contains("network/gateway/advertise") && hub.api.contains("network/gateway/remove") {
        NetworkCard {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("Share this device's internet")
              Text("Devices you allow can browse through this device's connection.").secondary()
            }
            Spacer()
            Toggle("Share this device's internet", isOn: Binding(
              get: { hub.net.isSharing },
              set: { enabled in Task { await updateGatewayServing(enabled) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(gatewayBusy)
          }
          if let gatewayError {
            Text(gatewayError).error()
          }
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

  private var gateways: [HubNet.Device] {
    hub.net.devices.sorted { ($0.name ?? $0.key) < ($1.name ?? $1.key) }
  }

  /// Only once a device offers its internet, or one is in use
  private var showsInternet: Bool {
    hub.api.contains("network/gateway/list") && hub.api.contains("network/gateway/grant")
      && (!gateways.isEmpty || hub.net.vpn != nil)
  }

  private var internet: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader("Internet through another device", "Your internet traffic goes through the device you choose, like a VPN.")
      NetworkCard {
        ForEach(Array(gateways.enumerated()), id: \.element.id) { index, device in
          if index > 0 { Divider() }
          let inUse = hub.net.vpn?.id == device.id
          HStack(spacing: 12) {
            Image(systemName: Device.symbol(platform: device.platform))
              .font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
              Text(device.name ?? device.key.shortNetworkKey)
              Text(gatewaySubtitle(device, inUse: inUse)).secondary()
            }
            Spacer()
            Button(inUse ? "Stop" : "Use") {
              Task { inUse ? await disableGateway() : await useGateway(device) }
            }
            .buttonStyle(.bordered)
            .tint(inUse ? .red : nil)
          }
        }
        if let gatewayUseError {
          Text(gatewayUseError).error()
        }
      }
    }
  }

  private func gatewaySubtitle(_ device: HubNet.Device, inUse: Bool) -> String {
    var values = [String]()
    if inUse { values.append(String(localized: "In use")) }
    if !device.capability.ipv6 { values.append(String(localized: "IPv4 only")) }
    if device.capability.metered { values.append(String(localized: "Metered")) }
    return values.isEmpty ? String(localized: "Available") : values.joined(separator: " · ")
  }

  @MainActor
  private func useGateway(_ device: HubNet.Device) async {
    gatewayUseError = nil
    do {
      try await hub.net.vpn(through: device)
    } catch {
      gatewayUseError = error.networkMessage
    }
  }

  @MainActor
  private func disableGateway() async {
    gatewayUseError = nil
    do {
      try await hub.net.disableVpn()
    } catch {
      gatewayUseError = error.networkMessage
    }
  }

  // MARK: Services

  private var services: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader("Services", "Shared on this network by its devices.")
      NetworkCard {
        let sorted = resources.sorted { $0.shareName < $1.shareName }
        ForEach(Array(sorted.enumerated()), id: \.element.id) { index, resource in
          if index > 0 { Divider() }
          NetworkResourceRow(
            resource: resource,
            status: connectionStatuses.first { $0.resourceId == resource.resourceId }
          )
        }
      }
    }
  }

  // MARK: Problems

  private var problems: [HubNetworkDiagnostic] {
    let visible = diagnostics.isEmpty ? connectionStatuses : diagnostics
    return visible.filter { $0.phase == .failed }
  }

  private var problemsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader("Connection problems", nil)
      NetworkCard {
        ForEach(Array(problems.enumerated()), id: \.element.id) { index, problem in
          if index > 0 { Divider() }
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
              Text(resources.first { $0.resourceId == problem.resourceId }?.shareName ?? problem.resourceId.shortNetworkKey)
              Text(problem.error?.message ?? String(localized: "Couldn't connect directly")).secondary()
            }
            Spacer(minLength: 0)
            if let date = problem.updatedAt.networkDate {
              Text(date, format: .relative(presentation: .named)).secondary()
            }
          }
        }
      }
    }
  }

  // MARK: Details

  private var details: some View {
    DisclosureGroup("Details") {
      NetworkCard {
        detailRow("Hub") { Text(hub.settings.name) }
        if hub.api.contains("hub/net/node") {
          Divider()
          detailRow("Node") {
            HStack {
              Text(hasNode ? node ?? "" : String(localized: "Not set"))
              if canSetNode && hasNode {
                Button(isEditingNode ? "Cancel" : "Change") {
                  isEditingNode.toggle()
                  nodeInput = ""
                  nodeError = nil
                }
                .buttonStyle(.borderless)
              }
            }
          }
          if isEditingNode {
            nodeField
          }
        }
        if let address = hub.net.address {
          Divider()
          detailRow("IPv4") { Text(address.ipv4) }
          Divider()
          detailRow("IPv6") { Text(address.ipv6) }
        }
        if canInvite {
          Divider()
          detailRow("Invitations") {
            Text(canCreateInvitation
                 ? String(localized: "Ready")
                 : hub.net.isJoined ? String(localized: "Waiting for this device") : String(localized: "Join the network first"))
          }
        }
      }
      .padding(.top, 8)
    }
    .foregroundStyle(.secondary)
  }

  private func detailRow<Value: View>(_ title: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
    HStack {
      Text(title)
      Spacer()
      value()
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private func sectionHeader(_ title: LocalizedStringKey, _ subtitle: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.headline)
      if let subtitle {
        Text(subtitle).secondary()
      }
    }
  }
}

/// Rows in one rounded group, separated by the dividers the caller puts between them
private struct NetworkCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
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
    HStack(spacing: 12) {
      Image(systemName: Device.symbol(platform: platform))
        .font(.title3)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(name)
          if isThisDevice {
            Text("This device")
              .note()
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.quaternary, in: .capsule)
          }
        }
        Text(subtitle).secondary()
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      if let address {
        Button(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc") {
          address.copyToClipboard()
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
          }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(online ? .primary : .secondary)
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
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.title3)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(resource.shareName)
          Text(subtitle).secondary()
        }
        .lineLimit(1)
        Spacer(minLength: 0)
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
          Image(systemName: "ellipsis.circle").font(.title3)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      Text(resource.authority)
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .padding(.leading, 40)
      if let connectionError {
        Text(connectionError).error().padding(.leading, 40)
      }
    }
    .hubStream(
      "network/providers/list",
      NetworkProviderRequest(resourceId: resource.resourceId),
      initial: [],
      to: $providers
    )
    .sheet(isPresented: $isEditingPolicy) {
      NetworkPolicyEditor(resource: resource)
    }
    .alert("Connect Directly", isPresented: $isConnectingDirectly) {
      TextField("host:port", text: $peerEndpoint)
        .autocorrectionDisabled()
      Button("Cancel", role: .cancel) { }
      Button("Connect") {
        guard let provider = providers.first else { return }
        Task { await connect(provider: provider) }
      }
    } message: {
      Text("Enter the UDP endpoint of the device that provides \(resource.shareName).")
    }
  }

  private var subtitle: String {
    var parts = [String]()
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
  @Environment(\.dismiss) private var dismiss
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
    NavigationStack {
      Form {
        Section {
          Picker("Who can connect", selection: $mode) {
            Text("Everyone on this Hub").tag(HubNetworkPolicyMode.hub)
            Text("A permission group").tag(HubNetworkPolicyMode.group)
            Text("Selected keys").tag(HubNetworkPolicyMode.keys)
            Text("Only its owner").tag(HubNetworkPolicyMode.private)
            Text("No one").tag(HubNetworkPolicyMode.disabled)
          }

          if mode == .group {
            TextField("Group name", text: $group)
          } else if mode == .keys {
            TextField("One key per line", text: $keys, axis: .vertical)
              .lineLimit(4...10)
          }
        } footer: {
          Text("Owned by \(resource.ownerKey.shortNetworkKey)")
        }

        Section {
          Button("Disconnect Everyone Now", systemImage: "bolt.shield", role: .destructive) {
            confirmsRevocation = true
          }
        } footer: {
          Text("Ends every connection to \(resource.shareName). Devices that are still allowed reconnect with new access.")
        }

        if let errorMessage {
          Section {
            Text(errorMessage).foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(resource.shareName)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task { await save() }
          }
          .disabled(isSaving || !isValid)
        }
      }
      .confirmationDialog(
        "Disconnect everyone from \(resource.shareName)?",
        isPresented: $confirmsRevocation,
        titleVisibility: .visible
      ) {
        Button("Disconnect", role: .destructive) {
          Task { await revoke() }
        }
      } message: {
        Text("Devices that are still allowed can connect again.")
      }
    }
    .frame(minWidth: 420, minHeight: 360)
    .interactiveDismissDisabled(isSaving)
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
  @Environment(\.dismiss) private var dismiss
  let link: String
  @State private var copied = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
#if canImport(HubServer)
          QRCodeView(text: link)
            .frame(width: 200, height: 200)
            .padding(12)
            .background(.white, in: .rect(cornerRadius: 20))
#endif
          Text("Scan this with your other device's camera, or send it the link.")
            .multilineTextAlignment(.center)
          Text(link)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
          HStack {
            Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
              link.copyToClipboard()
              copied = true
            }
            if let url = URL(string: link) {
              ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
          }
          .buttonStyle(.bordered)
          Text("The link works once, for seven days. On the other device, open it or paste it into Join Network on Hub's home screen.")
            .secondary()
            .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
      }
      .navigationTitle("Invite a Device")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .frame(minWidth: 400, minHeight: 540)
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

private extension HubNetworkAgent {
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
