//
//  AddDevice.swift
//  Hub
//
//  Add a Device: an invitation as a code beside three numbered steps, which says when the device joined.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct AddDeviceSheet: View {
  var facts = NetworkFacts()
  @Environment(Hub.self) private var hub
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom
  @State private var link: String?
  @State private var error: String?
  @State private var copied = false
  @State private var attempt = 0

  var body: some View {
    KitSheet(title: "Add a Device", meta: "To \(hub.settings.name)’s network", systemImage: "person.badge.plus", hue: .teal, width: 560) {
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
            link?.copyToClipboard()
            copied = true
          }
          .buttonStyle(.plain).foregroundStyle(.kitLink)
        }
        .kitFont(.caption)
      }
    } footer: {
      SheetStatus(
        error == nil ? "Waiting for the other device · works once, within 7 days" : "Couldn’t make an invitation",
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

  private var steps: some View {
    VStack(alignment: .leading, spacing: 14) {
      NumberedStep(1, "Open Hub on the other device", "A Mac, iPhone or iPad. Install Hub first if it isn’t there.")
      NumberedStep(2, "Choose Add a Hub, then Scan Code", "Point it at this code.")
      NumberedStep(3, "That’s it", "It joins on its own. You don’t need to approve anything here.")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func create() async {
    error = nil
    link = nil
    if hub.isDemo {
      link = NetworkInvitationParser.urlPrefix + "demo-invitation-\(hub.settings.name)"
      return
    }
    do {
      link = try await hub.net.createInviteCode()
    } catch is CancellationError {
      error = "The connection helper didn’t confirm this \(KitDevice.name) in time. Try again in a moment."
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
