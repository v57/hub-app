//
//  InternetOnly.swift
//  Hub
//
//  Hub for internet only: browse through your own Mac or server from anywhere, like a VPN that's yours. The Mac
//  that shares walks four steps (a private hub, its internet, staying awake, the phone's code); the phone that
//  browses explains what it gets, scans the code, then joins and switches to that internet in one go.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

// MARK: - The phone

/// Browse Through My Own Internet: what it is, then the code of the device to browse through
struct BrowseOwnInternetSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  // Optional: a kit overlay may not carry the window's model
  @Environment(ShellModel.self) private var shell: ShellModel?
  /// A browse link opened from outside (the Mac's Copy Link in Use This Mac's Internet) goes straight to joining
  @State private var link: String? = NetworkInvitationRouter.main.pendingInput.isEmpty ? nil
    : NetworkInvitationLink.parse(NetworkInvitationRouter.main.consume()).link
  @State private var scanning = false
  @State private var input = ""
  @State private var error: String?

  var body: some View {
    Group {
      if let link {
        JoinNetworkSheet(link: link, useInternet: true).id(link)
      } else {
        explainer
      }
    }
    // A link opened while the sheet is up
    .onChange(of: NetworkInvitationRouter.main.pendingInput) { _, pending in
      if !pending.isEmpty, link == nil { link = NetworkInvitationLink.parse(NetworkInvitationRouter.main.consume()).link }
    }
  }

  private var explainer: some View {
    KitSheet(title: "Browse Through Your Own Internet", meta: "Like a VPN, but it’s yours", systemImage: "globe", hue: .indigo, width: 540) {
      route
      VStack(alignment: .leading, spacing: 12) {
        point("lock.shield", String(localized: "Safe on any Wi-Fi"), String(localized: "Cafés and hotels see only an encrypted connection."))
        point("house", String(localized: "As if you were home"), String(localized: "Sites see your home’s address and region."))
        point("person", String(localized: "Your own, nobody else’s"), String(localized: "It goes straight to your device. No VPN company in between."))
        point("desktopcomputer", String(localized: "You need Hub on that Mac"), String(localized: "Or on a Linux server. On the Mac: Use This Mac’s Internet Anywhere."))
      }
      .padding(.horizontal, 4)
#if os(iOS)
      if scanning {
        KitQRScanner { text in accept(text) }.frame(height: 260)
      }
#else
      FormCard {
        FormRow("Invitation", help: "The link the other device shows under Can’t scan?", systemImage: "link", hue: .indigo, error: error.map { "\($0)" },
                field: TextField("hub://browse/…", text: $input).kitFont(.mono).kitTextContent(.url).onSubmit { accept(input) })
      }
#endif
      if let error, scanning {
        Text(error).kitFont(.caption).foregroundStyle(Hue.red.text)
      }
    } footer: {
#if os(macOS) && canImport(HubServer)
      Button("Set Up This Mac…") { shell?.sheet = .internetSetup }
#endif
#if os(iOS)
      Button(scanning ? "Close Scanner" : "Scan Its Code") { scanning.toggle() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
#else
      Button("Continue") { accept(input) }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
#endif
    }
  }

  /// Your iPhone → Your Mac at home → Internet
  private var route: some View {
    HStack(spacing: 6) {
      stop(KitDevice.systemImage, String(localized: "Your \(KitDevice.name)"))
      arrow
      stop("desktopcomputer", String(localized: "Your Mac at home"))
      arrow
      stop("globe", String(localized: "Internet"))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(RoundedRectangle(cornerRadius: KitMetrics.radiusCard).fill(.kitFillSoft))
    .accessibilityElement(children: .combine)
  }

  private func stop(_ symbol: String, _ title: String) -> some View {
    VStack(spacing: 6) {
      Tile(systemImage: symbol, hue: .indigo, size: 36)
      Text(title).kitFont(.caption).multilineTextAlignment(.center)
    }
    .frame(minWidth: 84)
  }

  private var arrow: some View {
    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.kitTertiary).padding(.bottom, 18)
  }

  private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Hue.indigo.text).frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).kitFont(.headline)
        Text(detail).kitFont(.caption).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func accept(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      _ = try NetworkInvitationLink.decode(text)
      scanning = false
      link = NetworkInvitationLink.parse(text).link
    } catch let invitation as NetworkInvitationError {
      error = invitation.message
    } catch {
      self.error = String(localized: "Not a code from Hub")
    }
  }
}

// MARK: - The Mac

#if os(macOS) && canImport(HubServer)
/// Use This Mac's Internet Anywhere: four steps, each with its check, then Add a Device for the phone
struct InternetSetupSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  @State private var step = 1
  @State private var working = false
  @State private var error: String?
  @State private var hub: Hub?
  @State private var addingPhone = false

  var body: some View {
    if addingPhone, let hub {
      AddDeviceSheet(purpose: .internet).hub(hub)
    } else {
      steps
    }
  }

  private var steps: some View {
    KitSheet(title: "Use This Mac’s Internet Anywhere", meta: "Four steps, about a minute", systemImage: "globe", hue: .indigo, status: working ? .working : .idle, width: 540) {
      VStack(alignment: .leading, spacing: 14) {
        NumberedStep(1, String(localized: "Start a private hub on this Mac"), String(localized: "Hub sets it up; nothing to configure."), state: state(1))
        NumberedStep(2, String(localized: "Share this Mac’s internet"), working && step == 2 ? String(localized: "Choose Allow when your Mac asks to add a VPN.") : String(localized: "Your devices can browse through it."), state: state(2))
        NumberedStep(3, String(localized: "Keep this Mac awake while sharing"), String(localized: "So it answers when you’re away. It can sleep with the lid closed only on power."), state: state(3))
        NumberedStep(4, String(localized: "Add your phone"), String(localized: "Scan a code with it. It starts browsing through this Mac right away."), state: state(4))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
      Text("Your phone browses as if it were here: sites see this Mac’s address. Nothing passes through anyone else’s servers; v57.dev only helps the two find each other.")
        .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
      if let error {
        Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).fixedSize(horizontal: false, vertical: true)
      }
    } footer: {
      SheetStatus("Step \(step) of 4", systemImage: "list.number", hue: .indigo)
      if step > 1 {
        Button("Back") { step -= 1 }.disabled(working)
      } else {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
      }
      Button(error == nil ? "Continue" : "Try Again") { Task { await run() } }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(working)
    }
    .kitSheetDismissDisabled(working)
  }

  private func state(_ number: Int) -> NumberedStep.State {
    number < step ? .done : number == step && working ? .working : .waiting
  }

  /// Does the current step, then moves to the next
  private func run() async {
    working = true
    error = nil
    defer { working = false }
    do {
      switch step {
      case 1: hub = try await startHub()
      case 2: try await shareInternet()
      case 3: KeepAwake.main.isOn = true
      default:
        addingPhone = true
        return
      }
      step += 1
    } catch {
      self.error = error.networkLine
    }
  }

  /// This Mac's own hub, running and connected
  private func startHub() async throws -> Hub {
#if DEBUG
    if HubDemo.isOn {
      try await Task.sleep(for: .seconds(1))
      guard let home = Hubs.main.list.first(where: { $0.settings.name == "Home" }) else { throw CancellationError() }
      return home
    }
#endif
    let local = LocalHub.main
    if !local.isRunning { await local.setEnabled(true) }
    if let error = local.error { throw SetupError(error) }
    for _ in 0..<60 {
      if let hub = Hubs.main.list.first(where: { $0.settings.address == local.localURL }), hub.isConnected { return hub }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw SetupError("This Mac’s hub didn’t start in time. Try again.")
  }

  private func shareInternet() async throws {
    guard let hub else { throw SetupError("Start the hub first.") }
#if DEBUG
    if hub.isDemo {
      try await Task.sleep(for: .seconds(1))
      hub.net.demo(sharing: true)
      return
    }
#endif
    if !hub.net.isJoined { try await hub.net.joinNetwork(enabled: true) }
    if !hub.net.isSharing { try await hub.net.shareInternet(true) }
  }

  private struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
#endif
#endif
