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

struct HubNetworkView: View {
  @Environment(Hub.self) private var hub
  @HubState(\.networkResources) private var resources
  @HubState(\.networkAgents) private var agents
  @HubState(\.networkAgentStatus) private var agentStatuses
  @HubState(\.networkConnectionStatus) private var connectionStatuses
  @HubState(\.networkDiagnostics) private var diagnostics
  @HubState(\.networkLocalAgent) private var localAgent
  @HubState(\.hubNetAgents) private var hubNetAgents
  @State private var membershipBusy = false
  @State private var gatewayBusy = false
  @State private var gatewayError: String?
  @State private var shareNetworkError: String?
  @State private var isCreatingInvitation = false
  @State private var invitationConfirmation: String?
  @State private var invitationError: String?
  @State private var gatewayUseError: String?
  @State private var tcpPort = ""
  @State private var udpPort = ""
  @State private var portError: String?
  @HubState(\.hubNetNode) private var node
  @State private var nodeInput = ""
  @State private var nodeError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        shareNetworkSection
        portSharingSection
        if hub.api.contains("hub/net/list") || hub.api.contains("hub/net/local-agent") {
          invitationSection
        }
        if hub.api.contains("network/gateway/advertise")
          && hub.api.contains("network/gateway/remove") {
          gatewayServingSection
        }
        if hub.api.contains("network/gateway/list")
          && hub.api.contains("network/gateway/grant") {
          gatewaySelectionSection
        }
        if hub.api.contains("network/resource/list") {
          resourcesSection
        }
        if hub.api.contains("network/agents/list") || hub.api.contains("network/status/agents") {
          agentsSection
        }
        if hub.api.contains("network/status/connections") || hub.api.contains("network/diagnostics") {
          diagnosticsSection
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .safeAreaPadding(.horizontal)
      .padding(.bottom)
    }
    .navigationTitle("Hub Network")
    .task {
      await hub.net.restoreIfActive()
    }
  }

  private var invitationSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Invite Code").font(.headline)
          Text("Create a single-use link valid for seven days.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Copy Invite Code", systemImage: "doc.on.doc") {
          Task { await createInvitation() }
        }
        .disabled(!canCreateInvitation || isCreatingInvitation)
      }
      nodeSection
      LabeledContent("Bootstrap readiness", value: localAgent.readinessLabel)
      if let invitationConfirmation {
        Label(invitationConfirmation, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }
      if let invitationError {
        Text(invitationError).font(.caption).foregroundStyle(.red)
      } else if hub.api.contains("hub/net/share"),
                let readinessHelp = localAgent.readinessHelp {
        Text(readinessHelp)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .background(.regularMaterial, in: .rect(cornerRadius: 16))
  }

  /// Invitations name the hub's node; there is no default one, so an owner sets it here
  @ViewBuilder private var nodeSection: some View {
    if hub.api.contains("hub/net/node") {
      if let node, !node.isEmpty {
        LabeledContent("Node", value: node)
      } else {
        Label(hub.api.contains("hub/net/node/set")
              ? "Set the Hub Network node before inviting devices."
              : "This Hub has no Hub Network node yet. Ask an owner to set one.",
              systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if hub.api.contains("hub/net/node/set") {
        HStack {
          TextField(node ?? "node.example.com:7000", text: $nodeInput)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
          AsyncButton("Set Node") {
            nodeError = nil
            do {
              try await hub.net.setNode(nodeInput)
              nodeInput = ""
            } catch {
              nodeError = String(error.localizedDescription.prefix(240))
            }
          }.disabled(nodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let nodeError {
          Text(nodeError).font(.caption).foregroundStyle(.red)
        }
      }
    }
  }

  private var canCreateInvitation: Bool {
    node?.isEmpty == false
      && hub.api.contains("hub/net/list")
      && hubNetAgents.contains(where: { $0.localIp == "127.0.0.1" })
      && localAgent.canIssueInvitation
  }

  @MainActor
  private func createInvitation() async {
    isCreatingInvitation = true
    invitationConfirmation = nil
    invitationError = nil
    defer { isCreatingInvitation = false }
    do {
      let code = try await hub.net.createInviteCode()
      code.copyToClipboard()
      invitationConfirmation = "Copied."
    } catch {
      invitationError = String(error.localizedDescription.prefix(240))
    }
  }

  private var shareNetworkSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Join Network", isOn: Binding(
        get: { hub.net.isJoined },
        set: { enabled in
          Task { await updateShareNetwork(enabled) }
        }
      ))
      .disabled(membershipBusy)
      Text("Join this Hub's private network. macOS may ask permission to install and activate a VPN profile.")
        .font(.caption)
        .foregroundStyle(.secondary)
      LabeledContent("Membership", value: hub.net.isJoined ? "Active" : "Inactive")
      if let address = hub.net.address {
        LabeledContent("IPv4", value: address.ipv4)
        LabeledContent("IPv6", value: address.ipv6)
      }
      if let shareNetworkError {
        Text(shareNetworkError).font(.caption).foregroundStyle(.red)
      } else if let agentError = hub.networkAppAgent.errorMessage {
        Text("Local agent: \(agentError)")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding()
    .background(.regularMaterial, in: .rect(cornerRadius: 16))
  }

  @MainActor
  private func updateShareNetwork(_ enabled: Bool) async {
    shareNetworkError = nil
    membershipBusy = true
    defer { membershipBusy = false }
    do {
      try await hub.net.joinNetwork(enabled: enabled)
    } catch {
      shareNetworkError = String(describing: error)
    }
  }

  private var portSharingSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Share Local Ports").font(.headline)
      portSharingRow(
        title: "TCP port",
        value: $tcpPort,
        shared: hub.net.sharedTcp,
        update: hub.net.shareTcp
      )
      portSharingRow(
        title: "UDP port",
        value: $udpPort,
        shared: hub.net.sharedUdp,
        update: hub.net.shareUdp
      )
      if !hub.net.sharedTcp.isEmpty {
        LabeledContent("Shared TCP", value: hub.net.sharedTcp.sorted().map(String.init).joined(separator: ", "))
      }
      if !hub.net.sharedUdp.isEmpty {
        LabeledContent("Shared UDP", value: hub.net.sharedUdp.sorted().map(String.init).joined(separator: ", "))
      }
      if let portError {
        Text(portError).font(.caption).foregroundStyle(.red)
      }
    }
    .padding()
    .background(.regularMaterial, in: .rect(cornerRadius: 16))
  }

  private func portSharingRow(
    title: String,
    value: Binding<String>,
    shared: Set<Int>,
    update: @escaping @MainActor (Int, Bool) async throws -> Void
  ) -> some View {
    HStack {
      TextField(title, text: value)
        .textFieldStyle(.roundedBorder)
      let port = Int(value.wrappedValue)
      let enabled = port.map(shared.contains) ?? false
      Button(enabled ? "Stop Sharing" : "Share") {
        guard let port else { return }
        Task {
          portError = nil
          do {
            try await update(port, !enabled)
          } catch {
            portError = error.localizedDescription
          }
        }
      }
      .disabled(port == nil || !hub.net.isJoined)
    }
  }

  private var gatewayServingSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Share Network", isOn: Binding(
        get: { hub.net.isSharing },
        set: { enabled in
          Task { await updateGatewayServing(enabled) }
        }
      ))
      .disabled(gatewayBusy || !hub.net.isJoined)
      Text("Disabled by default. When enabled, authorized Hub peers may use this Mac for IPv4, IPv6, and DNS internet access.")
        .font(.caption)
        .foregroundStyle(.secondary)
      LabeledContent("Gateway status", value: hub.net.isSharing ? "Available" : "Disabled")
      if let gatewayError {
        Text(gatewayError).font(.caption).foregroundStyle(.red)
      }
    }
    .padding()
    .background(.regularMaterial, in: .rect(cornerRadius: 16))
  }

  private var gatewaySelectionSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Internet Gateway").font(.headline)
      Text("Selection is explicit. Only reachable, enabled peers with IPv4 or IPv6 and DNS appear.")
        .font(.caption)
        .foregroundStyle(.secondary)
      let visible = hub.net.devices.sorted { $0.key < $1.key }
      if visible.isEmpty {
        Text("No reachable gateways.").secondary()
      } else {
        ForEach(visible) { device in
          HStack {
            VStack(alignment: .leading) {
              Text(device.name ?? device.key.shortNetworkKey)
              Text(gatewayCapabilityLabel(device))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(
              hub.net.vpn?.id == device.id
                ? "Disable"
                : "Use"
            ) {
              Task {
                if hub.net.vpn?.id == device.id {
                  await disableGateway()
                } else {
                  await useGateway(device)
                }
              }
            }
          }
        }
        Text("Selection is explicit and installs IPv4, IPv6, and DNS defaults only after grant validation.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let gatewayUseError {
        Text(gatewayUseError).font(.caption).foregroundStyle(.red)
      }
    }
    .padding()
    .background(.regularMaterial, in: .rect(cornerRadius: 16))
  }

  private func gatewayCapabilityLabel(_ device: HubNet.Device) -> String {
    var values = [String]()
    if device.capability.ipv4 { values.append("IPv4") }
    if device.capability.ipv6 { values.append("IPv6") }
    if device.capability.dns { values.append("DNS") }
    if device.capability.metered { values.append("Metered") }
    return values.joined(separator: " · ")
  }

  @MainActor
  private func useGateway(_ device: HubNet.Device) async {
    gatewayUseError = nil
    do {
      try await hub.net.vpn(through: device)
    } catch {
      gatewayUseError = error.localizedDescription
    }
  }

  @MainActor
  private func disableGateway() async {
    gatewayUseError = nil
    do {
      try await hub.net.disableVpn()
    } catch {
      gatewayUseError = error.localizedDescription
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
      gatewayError = error.localizedDescription
    }
  }

  private var header: some View {
    Placeholder(
      image: "network",
      title: "Hub Network",
      description: "Private TCP and UDP shares available through this Hub"
    ) { }
  }

  @ViewBuilder
  private var resourcesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Shares").font(.title2).fontWeight(.semibold)
      if resources.isEmpty {
        ContentUnavailableView(
          "No Network Shares",
          systemImage: "network.slash",
          description: Text("Published shares you can access will appear here.")
        )
      } else {
        LazyVGrid(minWidth: 280) {
          ForEach(resources.sorted(by: { $0.shareName < $1.shareName })) { resource in
            NetworkResourceView(
              resource: resource,
              status: connectionStatuses.first(where: { $0.resourceId == resource.resourceId })
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private var agentsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Agents").font(.title2).fontWeight(.semibold)
      if agents.isEmpty && agentStatuses.isEmpty {
        Text("No visible network agents are connected.").secondary()
      } else {
        LazyVGrid(minWidth: 280) {
          ForEach(keys, id: \.self) { key in
            NetworkAgentView(
              agent: agents.first(where: { $0.key == key }),
              status: agentStatuses.first(where: { $0.key == key })
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private var diagnosticsSection: some View {
    let visibleDiagnostics = diagnostics.isEmpty
      ? connectionStatuses.filter { $0.phase == .failed }
      : diagnostics
    VStack(alignment: .leading, spacing: 12) {
      Text("Direct Connection Diagnostics").font(.title2).fontWeight(.semibold)
      if visibleDiagnostics.isEmpty {
        Label("No direct-connect failures", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(visibleDiagnostics) { diagnostic in
            NetworkDiagnosticView(diagnostic: diagnostic)
          }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
      }
    }
  }

  private var keys: [String] {
    Set(agents.map(\.key) + agentStatuses.map(\.key)).sorted()
  }
}

private struct NetworkResourceView: View {
  @Environment(Hub.self) private var hub
  let resource: HubNetworkResource
  let status: HubNetworkConnectionStatus?
  @State private var providers = [HubNetworkProvider]()
  @State private var isEditingPolicy = false
  @State private var peerEndpoint = ""
  @State private var isConnecting = false
  @State private var connectionError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(resource.shareName, systemImage: "point.3.connected.trianglepath.dotted")
          .font(.headline)
        Spacer(minLength: 8)
        availability
      }
      Text(resource.authority)
        .font(.caption.monospaced())
        .textSelection(.enabled)
      LabeledContent("Owner", value: resource.ownerKey.shortNetworkKey)
      LabeledContent("Access", value: resource.policy.label)
      LabeledContent("Providers", value: "\(providers.count)")
      if let status {
        LabeledContent("Connection", value: status.phase.label)
      }
      if let provider = providers.first {
        Divider()
        TextField("Peer UDP endpoint (host:port)", text: $peerEndpoint)
          .textFieldStyle(.roundedBorder)
        Button("Connect App Profile", systemImage: "network") {
          Task { await connect(provider: provider) }
        }
        .disabled(isConnecting || peerEndpoint.isEmpty)
      }
      if let connectionError {
        Text(connectionError).font(.caption).foregroundStyle(.red)
      }
      if hub.canManageNetwork {
        Divider()
        Button("Manage Access", systemImage: "person.badge.key") {
          isEditingPolicy = true
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 16))
    .hubStream(
      "network/providers/list",
      NetworkProviderRequest(resourceId: resource.resourceId),
      initial: [],
      to: $providers
    )
    .sheet(isPresented: $isEditingPolicy) {
      NetworkPolicyEditor(resource: resource)
    }
  }

  @MainActor
  private func connect(provider: HubNetworkProvider) async {
    isConnecting = true
    connectionError = nil
    defer { isConnecting = false }
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
      connectionError = error.localizedDescription
    }
  }

  @ViewBuilder
  private var availability: some View {
    if providers.isEmpty {
      Text("Unavailable").foregroundStyle(.secondary)
    } else {
      Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
        Section("Access") {
          Picker("Policy", selection: $mode) {
            Text("Everyone on this Hub").tag(HubNetworkPolicyMode.hub)
            Text("Permission group").tag(HubNetworkPolicyMode.group)
            Text("Selected keys").tag(HubNetworkPolicyMode.keys)
            Text("Private").tag(HubNetworkPolicyMode.private)
            Text("Disabled").tag(HubNetworkPolicyMode.disabled)
          }

          if mode == .group {
            TextField("Group name", text: $group)
          } else if mode == .keys {
            TextField("One profile key per line", text: $keys, axis: .vertical)
              .lineLimit(4...10)
          }
        }

        Section {
          LabeledContent("Share", value: resource.shareName)
          LabeledContent("Owner", value: resource.ownerKey.shortNetworkKey)
          LabeledContent("Generation", value: "\(resource.generation)")
        }

        Section {
          Button("Revoke Active Access", systemImage: "bolt.shield", role: .destructive) {
            confirmsRevocation = true
          }
          Text("Revocation increments the resource generation so connected agents can terminate access granted under older generations.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let errorMessage {
          Section {
            Text(errorMessage).foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Manage Network Share")
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
        "Revoke active access to \(resource.shareName)?",
        isPresented: $confirmsRevocation,
        titleVisibility: .visible
      ) {
        Button("Revoke Access", role: .destructive) {
          Task { await revoke() }
        }
      } message: {
        Text("New grants will use the next generation. Existing agents are notified immediately.")
      }
    }
    .frame(minWidth: 440, minHeight: 480)
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
      errorMessage = error.localizedDescription
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
      errorMessage = error.localizedDescription
    }
  }
}

private struct NetworkAgentView: View {
  let agent: HubNetworkAgent?
  let status: HubNetworkAgentStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(agent?.displayName ?? "Network Agent", systemImage: "desktopcomputer")
          .font(.headline)
        Spacer(minLength: 8)
        Circle()
          .fill(status?.available == true ? .green : .secondary)
          .frame(width: 8, height: 8)
      }
      if let platform = agent?.platform {
        LabeledContent("Platform", value: platform)
      }
      LabeledContent("Address", value: (status?.addresses ?? agent?.overlayAddresses ?? []).joined(separator: ", "))
      if let status {
        LabeledContent("Peers", value: "\(status.peers)")
        LabeledContent("Shares", value: "\(status.shares)")
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 16))
  }
}

private struct NetworkDiagnosticView: View {
  let diagnostic: HubNetworkDiagnostic

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: diagnostic.phase == .failed ? "exclamationmark.triangle.fill" : "info.circle.fill")
        .foregroundStyle(diagnostic.phase == .failed ? .orange : .secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(diagnostic.error?.message ?? diagnostic.phase.label)
        Text(diagnostic.resourceId).font(.caption.monospaced()).secondary()
        if let code = diagnostic.error?.code {
          Text(code.rawValue).font(.caption).secondary()
        }
      }
      Spacer(minLength: 0)
      Text(diagnostic.updatedAt).font(.caption).secondary()
    }
  }
}

private struct NetworkProviderRequest: Encodable, Hashable, Sendable {
  let resourceId: String
}

private extension HubNetworkPolicy {
  var label: String {
    switch mode {
    case .hub: "Everyone on this Hub"
    case .group: group.map { "Group: \($0)" } ?? "Group"
    case .keys: "\(keys?.count ?? 0) selected keys"
    case .private: "Private"
    case .disabled: "Disabled"
    }
  }
}

private extension HubNetworkConnectionPhase {
  var label: String {
    switch self {
    case .idle: "Idle"
    case .discovering: "Discovering"
    case .connecting: "Connecting"
    case .connected: "Connected directly"
    case .failed: "Direct connection failed"
    }
  }
}

private extension HubNetworkAgent {
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
}
