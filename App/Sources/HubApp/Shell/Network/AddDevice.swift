//
//  AddDevice.swift
//  Hub
//
//  Add a Device: an invitation as a code beside three numbered steps, which says when the device joined: the devices
//  on the network when the code appeared are known, and the first one that wasn't is the one that used it.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct AddDeviceSheet: View {
  var facts = NetworkFacts()
  /// What the device is for: reaching this hub's devices, or browsing through this Mac's internet
  @State private var purpose: Purpose
  @State private var turningOnSharing = false
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom
  @State private var link: String?
  @State private var error: String?
  @State private var copied = false
  @State private var attempt = 0
  /// The devices on the network when the code appeared
  @State private var known: Set<String>?

  enum Purpose: Hashable { case devices, internet }

  init(purpose: Purpose = .devices) {
    _purpose = State(initialValue: purpose)
  }

  /// Only a device that can share its internet offers the choice
  private var offersInternet: Bool {
#if os(macOS)
    hub.api.contains("network/gateway/advertise")
#else
    false
#endif
  }

  /// The device that joined while the code was shown
  private var joined: NetDevice? {
    guard let known else { return nil }
    return facts.devices.first { !known.contains($0.id) && $0.status != .thisDevice }
  }

  var body: some View {
    if let joined {
      joinedSheet(joined)
    } else {
      inviteSheet
    }
  }

  private func joinedSheet(_ device: NetDevice) -> some View {
    KitSheet(title: "Add a Device", meta: "To \(hub.settings.name)’s network", systemImage: "person.badge.plus", hue: .teal, width: 560) {
      VStack(spacing: 10) {
        ZStack(alignment: .bottomTrailing) {
          Tile(systemImage: device.symbol, hue: .teal, size: 56)
          Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white, Hue.green.fill).offset(x: 6, y: 6)
        }
        .padding(.bottom, 4)
        Text("\(device.name) joined \(hub.settings.name)").kitFont(.title3)
        Text("It can reach your devices now, and they can reach it.").kitFont(.body).foregroundStyle(.kitSecondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
    } footer: {
      let count = facts.devices.count
      SheetStatus("\(hub.settings.name) has \(count == 1 ? "1 device" : "\(count) devices")", systemImage: "checkmark", hue: .green)
      Button("Add Another") {
        known = nil
        attempt += 1
      }
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  private var inviteSheet: some View {
    KitSheet(
      title: "Add a Device", meta: purpose == .internet ? "To browse through \(facts.thisName)" : "To \(hub.settings.name)’s network",
      systemImage: "person.badge.plus", hue: .teal, width: 560
    ) {
      if offersInternet {
        KitSegmented(selection: $purpose, options: [("Reach My Devices", Purpose.devices), ("Use This Mac’s Internet", Purpose.internet)])
          .frame(maxWidth: .infinity)
      }
      if idiom == .phone {
        VStack(spacing: 16) {
          code
          steps
        }
      } else {
        HStack(alignment: .top, spacing: 20) {
          code
          steps
        }
      }
      if link != nil {
        HStack(spacing: 4) {
          Text("Can’t scan?")
#if !os(tvOS)
          if let link, let url = URL(string: link) {
            ShareLink(item: url) { Text("Send a link instead") }.buttonStyle(.plain).foregroundStyle(.kitLink)
            Text("·")
          }
#endif
          Button(copied ? "Copied" : "Copy Link") {
            if let link { KitPasteboard.copy(link) }
            copied = true
          }
          .buttonStyle(.plain).foregroundStyle(.kitLink)
        }
        .kitFont(.caption)
      }
    } footer: {
      SheetStatus(
        error != nil ? "Couldn’t make an invitation"
          : purpose == .internet ? "Waiting for your phone · works once, within 7 days" : "Waiting for the other device · works once, within 7 days",
        systemImage: "person.badge.plus", hue: error == nil ? .teal : .red, status: link != nil && error == nil ? .working : .idle
      )
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
    .task(id: attempt) { await create() }
  }

  @ViewBuilder
  private var code: some View {
    Group {
      if let link {
        KitQRCode(link, size: 168)
      } else if let error {
        VStack(spacing: 8) {
          Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).multilineTextAlignment(.center)
          Button("Try Again") { attempt += 1 }.buttonStyle(.kit).controlSize(.small)
        }
        .padding(8)
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .frame(width: 180, height: 180)
    .background(RoundedRectangle(cornerRadius: KitMetrics.radiusCard).fill(.kitFillSoft))
  }

  @ViewBuilder
  private var steps: some View {
    VStack(alignment: .leading, spacing: 14) {
      if purpose == .internet {
        // The invitation doesn't say what it's for yet, so the phone is told where to scan it
        NumberedStep(1, "Install Hub on your phone")
        NumberedStep(2, "Open it and choose Browse Through My Own Internet", "Then Scan Its Code, and point it here.")
        NumberedStep(3, "It browses through \(facts.thisName)", "Joining and the switch to this Mac’s internet happen together.")
        if !hub.net.isSharing {
          HStack(spacing: 8) {
            Text("This Mac doesn’t share its internet yet.").kitFont(.caption).foregroundStyle(Hue.orange.text)
            Button("Share It") {
              turningOnSharing = true
              Task {
                do { try await hub.net.shareInternet(true) } catch { self.error = error.networkLine }
                turningOnSharing = false
              }
            }
            .buttonStyle(.kit).controlSize(.small).disabled(turningOnSharing)
          }
        }
      } else {
        NumberedStep(1, "Open Hub on the other device", "A Mac, iPhone or iPad. Install Hub first if it isn’t there.")
        NumberedStep(2, "Choose Add a Hub, then Scan Code", "Point it at this code.")
        NumberedStep(3, "That’s it", "It joins on its own. You don’t need to approve anything here.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func create() async {
    error = nil
    link = nil
    if hub.isDemo {
      link = NetworkInvitationParser.urlPrefix + "demo-invitation-\(hub.settings.name)"
      known = Set(facts.devices.map(\.id))
#if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--demo-net-join") {
        try? await Task.sleep(for: .seconds(4))
        HubDemo.join("maya-ipad", platform: "ios", hub: hub)
      }
#endif
      return
    }
    do {
      link = try await hub.net.createInviteCode()
      known = Set(facts.devices.map(\.id))
    } catch is CancellationError {
      error = "The connection helper didn’t confirm this \(KitDevice.nameInSentence) in time. Try again in a moment."
    } catch {
      self.error = error.networkLine
    }
  }
}

/// A numbered step: "1  Open Hub on the other device / A Mac, iPhone or iPad."
struct NumberedStep: View {
  let number: Int
  let title: String
  let detail: String?
  var state: State = .waiting

  enum State { case waiting, working, done }

  init(_ number: Int, _ title: String, _ detail: String? = nil, state: State = .waiting) {
    self.number = number
    self.title = title
    self.detail = detail
    self.state = state
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ZStack {
        Circle().fill(state == .done ? AnyShapeStyle(Hue.green.fill) : AnyShapeStyle(.kitFill))
        switch state {
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        case .working: ProgressView().controlSize(.mini)
        case .waiting: Text("\(number)").kitFont(.caption).fontWeight(.semibold).foregroundStyle(.kitLabel)
        }
      }
      .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).kitFont(.headline)
        if let detail {
          Text(detail).kitFont(.caption).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
#endif
