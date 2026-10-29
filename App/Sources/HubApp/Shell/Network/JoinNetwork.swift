//
//  JoinNetwork.swift
//  Hub
//
//  Joining a hub's network from an invitation: what joining means before it happens, the VPN the system is about to
//  ask for (only the first time), three steps, and You're in. A failure says what happened and what to do, with the
//  raw message under Details. Joined to use the inviting device's internet (Browse Through My Own Internet), it asks
//  "Use studio-mac's Internet?" instead and switches to that internet once it's in.
//
//  The invitation doesn't carry the hub's name: it's known here only when this device already knows the device that
//  invited it (through a hub it has open); otherwise the first screens say "the hub" and the name comes with the
//  hub's first reply.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct JoinNetworkSheet: View {
  let link: String
  /// Use the inviting device's internet once joined
  var useInternet = false
  @Environment(\.kitDismiss) private var dismiss
  @State private var stage: Stage
  @State private var nets = HubNets.main
  @State private var joined: Hub?
  @State private var showsDetails = false

  enum Stage: Equatable {
    case confirm, allowVPN, joining, joined, browsing
    case failed(JoinFailure)
  }

  init(link: String, useInternet: Bool = false, stage: Stage = .confirm) {
    self.link = link
    self.useInternet = useInternet
    _stage = State(initialValue: stage)
  }

  private var invitation: DecodedNetworkInvitation? { try? NetworkInvitationParser.decode(link) }

  /// The hub that sent it, when this device knows the device that invited it
  private var known: (hub: Hub, inviter: String?)? {
#if DEBUG
    if HubDemo.isOn, let home = Hubs.main.list.first(where: { $0.settings.name == "Home" }) { return (home, useInternet ? "studio-mac" : "home-nas") }
#endif
    guard let invitation else { return nil }
    for hub in Hubs.main.list {
      if let agent = hub.state.networkAgents.value.first(where: { $0.key == invitation.agentKey }) { return (hub, agent.name) }
    }
    return nil
  }

  private var hubName: String? { joined?.settings.name ?? known?.hub.settings.name }
  /// The inviting device's name, once this device knows it
  private var inviter: String? {
    if let joined, let invitation, let agent = joined.state.networkAgents.value.first(where: { $0.key == invitation.agentKey }) {
      return agent.name
    }
    return known?.inviter
  }
  private var possessive: String { hubName.map { "\($0)’s" } ?? "the hub’s" }

  var body: some View {
    switch stage {
    case .confirm: if useInternet { useConfirm } else { confirm }
    case .allowVPN: allowVPN
    case .joining: joining
    case .joined: done
    case .browsing: browsing
    case .failed(let failure): failed(failure)
    }
  }

  // MARK: Join?

  private var confirm: some View {
    KitSheet(
      title: hubName.map { "Join \($0)’s Network?" } ?? "Join This Hub’s Network?",
      meta: hubName.map { "Someone in \($0) invited this \(KitDevice.nameInSentence)" } ?? "Someone invited this \(KitDevice.nameInSentence) to their hub",
      systemImage: "person.badge.plus", hue: .teal, width: 520
    ) {
      FormCard {
        if let known {
          HStack(spacing: 10) {
            HubTile(hub: known.hub, size: 28)
            VStack(alignment: .leading, spacing: 1) {
              Text(known.hub.settings.name).kitFont(.headline)
              if let inviter = known.inviter { Text("Invited from \(inviter)").kitFont(.caption) }
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12).padding(.vertical, 10)
        } else if let invitation {
          FormRow("A hub’s network", help: "Finds it through \(URL(string: invitation.node)?.host ?? invitation.node)", systemImage: "hexagon", hue: .accent)
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        point("arrow.left.arrow.right", hubName.map { "Reach \($0)’s devices from anywhere" } ?? "Reach the hub’s devices from anywhere",
              "And they can reach this \(KitDevice.nameInSentence), at home or away.")
        point("lock", "Private", "Only devices in \(hubName ?? "the hub") can connect. Nothing passes through anyone else.")
        point("power", "Yours to switch off", "Turn it off any time in Hub Network.")
      }
      .padding(.horizontal, 4)
    } footer: {
      if let invitation {
        SheetStatus("Invitation works until \(invitation.expiresAt.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "clock", hue: .gray)
      }
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Join") { Task { await next() } }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  /// Joining to browse through the inviting device
  private var useConfirm: some View {
    KitSheet(
      title: inviter.map { "Use \($0)’s Internet?" } ?? "Use This Device’s Internet?",
      meta: "\(inviter ?? "The device that showed the code") invited this \(KitDevice.nameInSentence)",
      systemImage: "globe", hue: .indigo, width: 520
    ) {
      if let inviter {
        FormCard {
          FormRow(inviter, help: hubName.map { "Shares its internet · in \($0)" } ?? "Shares its internet", systemImage: "desktopcomputer", hue: .indigo)
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        point("globe", "Browse through \(inviter ?? "it")", "Starts as soon as this \(KitDevice.nameInSentence) joins.")
        point("switch.2", "Switch it from the Hub screen", "Use and Stop on the Hub Network card.")
      }
      .padding(.horizontal, 4)
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Join and Use") { Task { await next() } }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Hue.teal.text).frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).kitFont(.headline)
        Text(detail).kitFont(.caption).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: One More Step

  private var allowVPN: some View {
    KitSheet(title: "One More Step", meta: "Allow the VPN", systemImage: "lock.shield", hue: .teal, width: 520) {
      Text("Next, your \(KitDevice.nameInSentence) asks to add a VPN. Hub uses it to connect your devices privately; the rest of your internet works as before. Choose **Allow**.")
        .kitFont(.body).fixedSize(horizontal: false, vertical: true)
      // The system alert, drawn with Allow marked
      VStack(spacing: 10) {
        Image(systemName: "network.badge.shield.half.filled").font(.system(size: 28)).foregroundStyle(Hue.teal.text)
        Text("“Hub” Would Like to Add VPN Configurations").kitFont(.headline).multilineTextAlignment(.center)
        Text("All network activity on this \(KitDevice.nameInSentence) may be filtered or monitored when using VPN.")
          .kitFont(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Text("Allow").kitFont(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(Hue.blue.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Hue.teal.fill, lineWidth: 2).padding(-4))
          Text("Don’t Allow").kitFont(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(.kitFillSoft, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, 4)
      }
      .padding(16)
      .frame(maxWidth: 280)
      .background(RoundedRectangle(cornerRadius: KitMetrics.radiusCard).fill(.kitFillSoft))
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .combine)
    } footer: {
      SheetStatus("Asked once, the first time", systemImage: "info.circle", hue: .gray)
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Continue") { Task { await join() } }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  // MARK: Joining

  private var joining: some View {
    KitSheet(title: hubName.map { "Joining \($0)" } ?? "Joining", meta: "Hub Network", systemImage: "person.badge.plus", hue: .teal, status: .working, width: 520) {
      let step = Self.step(nets.joinProgress?.state)
      VStack(alignment: .leading, spacing: 14) {
        NumberedStep(1, "Checking the invitation", state: step > 1 ? .done : .working)
        NumberedStep(2, "Setting up a secure connection", state: step > 2 ? .done : step == 2 ? .working : .waiting)
        NumberedStep(3, hubName.map { "Connecting to \($0)…" } ?? "Connecting to the hub…", state: step == 3 ? .working : .waiting)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    } footer: {
      SheetStatus(nets.joinProgress?.state == .awaitingVPNConsent ? "Choose Allow when asked" : "A few seconds", systemImage: "clock", hue: .gray)
    }
    .kitSheetDismissDisabled(true)
  }

  /// The seven join states as the three steps people see
  private static func step(_ state: NativeJoinProgressState?) -> Int {
    switch state {
    case nil, .validating, .staging, .awaitingVPNConsent: 1
    case .startingTunnel, .rendezvous: 2
    case .connected, .binding, .recovering, .activating: 3
    }
  }

  // MARK: You're in

  private var done: some View {
    KitSheet(title: hubName.map { "Joined \($0)" } ?? "Joined", meta: "Hub Network", systemImage: "checkmark", hue: .green, width: 520) {
      VStack(spacing: 10) {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.white, Hue.green.fill)
        Text("You’re in").kitFont(.title3)
        Text(reach).kitFont(.body).foregroundStyle(.kitSecondary).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
    } footer: {
      Button("Show Devices") {
        if let joined { Navigator.main.open(joined, .network) }
        dismiss()
      }
      .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  private var reach: String {
    let start = "This \(KitDevice.name) is on \(possessive) network."
    let hub = joined ?? known?.hub
    let me = hub?.client.device?.key.id
    var names = hub?.state.networkAgents.value.filter { me == nil || $0.deviceId != me }.compactMap(\.name) ?? []
#if DEBUG
    if hub?.isDemo == true { names.removeAll { $0 == "studio-mac" } }
#endif
    switch names.count {
    case 0: return start + " Its devices can reach it too."
    case 1: return start + " It can reach \(names[0])."
    case 2: return start + " It can reach \(names[0]) and \(names[1])."
    default: return start + " It can reach \(names[0]), \(names[1]) and \(names.count - 2) more."
    }
  }

  // MARK: Browsing

  private var browsing: some View {
    KitSheet(title: inviter.map { "Using \($0)’s Internet" } ?? "Using Its Internet", meta: "Hub Network", systemImage: "globe", hue: .indigo, width: 520) {
      VStack(spacing: 10) {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.white, Hue.green.fill)
        Text("You’re browsing through \(inviter ?? "it")").kitFont(.title3)
        Text("Sites now see your home’s address. Stop any time from the Hub screen.").kitFont(.body).foregroundStyle(.kitSecondary)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
    } footer: {
      Button("Stop") {
        Task {
          try? await (joined ?? known?.hub)?.net.stopUsingInternet()
          dismiss()
        }
      }
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  // MARK: If it fails

  private func failed(_ failure: JoinFailure) -> some View {
    KitSheet(title: failure.title, meta: "Hub Network", systemImage: "exclamationmark.triangle", hue: .orange, width: 520) {
      Text(failure.detail).kitFont(.body).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Button {
          withAnimation(.kit) { showsDetails.toggle() }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showsDetails ? 90 : 0))
            Text("Details")
          }
          .kitFont(.caption)
        }
        .buttonStyle(.plain)
        if showsDetails {
          Text(failure.raw).kitFont(.mono).foregroundStyle(.kitSecondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } footer: {
      if failure.canRetry {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Try Again") { Task { await join() } }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      } else {
        Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: Actions

  /// One More Step before the first join, when the system hasn't asked about the VPN yet
  private func next() async {
#if DEBUG
    if HubDemo.isOn {
      stage = .allowVPN
      return
    }
#endif
    let tunnel = try? PacketTunnelController()
    if let tunnel, await tunnel.status == .notInstalled {
      stage = .allowVPN
    } else {
      await join()
    }
  }

  private func join() async {
    showsDetails = false
    stage = .joining
#if DEBUG
    if HubDemo.isOn {
      try? await Task.sleep(for: .seconds(2))
      stage = useInternet ? .browsing : .joined
      return
    }
#endif
    do {
      let hub = try await HubNets.main.join(link: link.trimmingCharacters(in: .whitespacesAndNewlines))
      joined = hub
      if useInternet {
        await use(hub)
      } else {
        stage = .joined
      }
    } catch {
      stage = .failed(JoinFailure(error, hub: hubName))
    }
  }

  /// Switches to the inviting device's internet once the hub lists it as sharing it
  private func use(_ hub: Hub) async {
    guard let key = invitation?.agentKey else { return }
    for _ in 0..<40 {
      if let gateway = hub.net.devices.first(where: { $0.key == key }) {
        do {
          try await hub.net.vpn(through: gateway)
          NetworkRecents.main.use(key, hub: hub, internet: true)
          stage = .browsing
        } catch {
          stage = .failed(JoinFailure(title: "Couldn’t use \(inviter.map { "\($0)’s" } ?? "its") internet",
                                      detail: "This \(KitDevice.name) joined \(hub.settings.name). Try Use on the Hub Network card in a moment.",
                                      raw: NativeJoinPresentation.error(error), canRetry: false))
        }
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    let name = inviter ?? "The device that showed the code"
    stage = .failed(JoinFailure(
      title: "\(name) doesn’t share its internet",
      detail: "This \(KitDevice.name) joined \(hub.settings.name). On \(inviter ?? "that device"), turn on Let your devices use this Mac’s internet, then choose Use on the Hub Network card.",
      raw: "No internet gateway from the inviting device", canRetry: false
    ))
  }
}

/// A join failure in plain words: what happened, what to do, and the raw message for Details
struct JoinFailure: Equatable {
  let title: String
  let detail: String
  let raw: String
  /// Trying the same invitation again can work
  let canRetry: Bool

  init(title: String, detail: String, raw: String, canRetry: Bool) {
    self.title = title
    self.detail = detail
    self.raw = raw
    self.canRetry = canRetry
  }

  @MainActor init(_ error: Error, hub: String?) {
    let raw = NativeJoinPresentation.error(error)
    let name = hub ?? "the hub"
    let device = KitDevice.name
    let lowered = raw.lowercased()
    self.raw = raw
    switch error {
    case let error as NetworkInvitationError where error.code == .expired:
      (title, detail, canRetry) = ("This invitation expired", "Invitations last seven days. Ask someone in \(name) for a new one.", false)
    case NativeJoinError.activeVPNConflict:
      let other = Hubs.main.list.first(where: \.net.isJoined)?.settings.name
      (title, detail, canRetry) = (
        other.map { "This \(device) is on \($0)’s network" } ?? "This \(device) is on another hub’s network",
        "A device can be on one hub’s network at a time. Turn off \(other.map { "\($0)’s" } ?? "that one") first.", true
      )
    case NativeJoinError.refused(.keyRefused):
      (title, detail, canRetry) = (
        "\(hub ?? "The hub") doesn’t accept this \(device)",
        "An owner removed it from \(name). If that’s a mistake, check this \(device)’s date and time.", false
      )
    case NativeJoinError.bootstrapTimedOut, NativeJoinError.staged(.rendezvous, _), NativeJoinError.staged(.connection, _):
      (title, detail, canRetry) = (
        "Couldn’t reach \(name)", "The Mac that runs \(name) may be asleep or offline. Try again once it’s on.", true
      )
    case HubNetDaemon.Failure.notRunning, HubNetDaemon.Failure.notPermitted:
      (title, detail, canRetry) = ("Hub Network isn’t set up on this \(device)", raw, true)
    case NativeJoinError.staged(.vpnInstall, _):
      (title, detail, canRetry) = ("You didn’t allow the VPN", "Hub needs it to connect your devices. Try again and choose Allow.", true)
    default:
      if lowered.contains("already used") || lowered.contains("replay") {
        (title, detail, canRetry) = ("This invitation was already used", "Each one works once. Ask someone in \(name) for a new one.", false)
      } else if lowered.contains("expired") {
        (title, detail, canRetry) = ("This invitation expired", "Invitations last seven days. Ask someone in \(name) for a new one.", false)
      } else {
        (title, detail, canRetry) = ("Couldn’t join \(name)", "Try again in a moment. If it keeps failing, ask for a new invitation.", true)
      }
    }
  }

#if DEBUG
  /// The board's failures, for `--net-sheet join:<kind>`
  @MainActor static func demo(_ kind: String) -> JoinFailure {
    switch kind {
    case "used": JoinFailure(NativeJoinError.staged(.bind, "invitation already used"), hub: "Home")
    case "expired": JoinFailure(NetworkInvitationError(code: .expired, message: "Invitation expired"), hub: "Home")
    case "unreachable": JoinFailure(NativeJoinError.bootstrapTimedOut, hub: "Home")
    case "vpn": JoinFailure(NativeJoinError.staged(.vpnInstall, "permission denied"), hub: "Home")
    case "other": JoinFailure(NativeJoinError.activeVPNConflict, hub: "Home")
    default: JoinFailure(NativeJoinError.refused(.keyRefused), hub: "Home")
    }
  }
#endif
}
#endif
