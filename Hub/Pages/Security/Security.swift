//
//  Security.swift
//  Hub
//
//  Deny-by-default mode and grants (hub/security/mode, hub/grants).
//

import SwiftUI
import HubService

struct SecurityView: View {
  @Environment(Hub.self) private var hub
  @HubState(\.securityMode) private var mode
  @HubState(\.grants) private var grants
  @HubState(\.devices) private var devices
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Placeholder(image: "lock.shield", title: "Security", description: """
          Deny by default: only owners, grants and public apis can be called
          Grants name a key, a device, a group or everyone
          """) {
          if mode.mode == .defaultAllow {
            Label("This hub allows calls without a grant. Switch to deny by default when your grants are in place.", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        VStack(alignment: .leading, spacing: 12) {
          Picker("Mode", selection: Binding(get: { mode.mode }, set: { set(mode: $0) })) {
            Text("Allow by default").tag(SecurityMode.Mode.defaultAllow)
            Text("Deny by default").tag(SecurityMode.Mode.defaultDeny)
          }.pickerStyle(.segmented)
          Toggle("Require hub-bound tokens", isOn: Binding(get: { mode.requireV1 }, set: { set(requireV1: $0) }))
          Text("Refuses clients that sign tokens for any hub (older apps and services).").secondary()
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Grants").sectionTitle()
          if grants.isEmpty {
            Text("No grants").secondary()
          }
          ForEach(grants) { grant in
            HStack {
              VStack(alignment: .leading) {
                Text(title(grant.subject))
                Text(title(grant.object)).secondary()
              }.lineLimit(1)
              Spacer(minLength: 0)
              AsyncButton("Remove", systemImage: "minus.circle") {
                try await hub.client.devices.removeGrant(grant.id)
              }.labelStyle(.iconOnly)
            }.padding(.vertical, 4)
          }
          NewGrantView(devices: devices.filter { $0.approved && !$0.revoked })
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(.horizontal)
    }
  }
  func set(mode: SecurityMode.Mode) {
    Task { try? await hub.client.devices.setSecurityMode(mode) }
  }
  func set(requireV1: Bool) {
    Task { try? await hub.client.devices.setSecurityMode(requireV1: requireV1) }
  }
  func title(_ subject: Grant.Subject) -> String {
    switch subject {
    case .everyone: String(localized: "Everyone")
    case .group(let group): String(localized: "Group \(group)")
    case .key(let key): String(localized: "Key …\(key.suffix(8))")
    case .device(let id): devices.first { $0.id == id }?.name ?? String(localized: "Device \(id.prefix(8))")
    }
  }
  func title(_ object: Grant.Object) -> String {
    switch object {
    case .path(let path): path
    case .prefix(let prefix): "\(prefix)*"
    case .share(let id): String(localized: "Share \(id.prefix(12))")
    }
  }

  struct NewGrantView: View {
    @Environment(Hub.self) private var hub
    let devices: [Device]
    enum SubjectKind: Hashable { case everyone, device, group, key }
    enum ObjectKind: Hashable { case prefix, path, share }
    @State private var subjectKind = SubjectKind.device
    @State private var device = ""
    @State private var subjectText = ""
    @State private var objectKind = ObjectKind.prefix
    @State private var objectText = ""
    var subject: Grant.Subject? {
      let text = subjectText.trimmingCharacters(in: .whitespacesAndNewlines)
      switch subjectKind {
      case .everyone: return .everyone
      case .device: return device.isEmpty ? nil : .device(device)
      case .group: return text.isEmpty ? nil : .group(text)
      case .key: return text.isEmpty ? nil : .key(text)
      }
    }
    var object: Grant.Object? {
      let text = objectText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      switch objectKind {
      case .prefix: return .prefix(text)
      case .path: return .path(text)
      case .share: return .share(text)
      }
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("New grant").secondary()
        Picker("Who", selection: $subjectKind) {
          Text("Device").tag(SubjectKind.device)
          Text("Group").tag(SubjectKind.group)
          Text("Key").tag(SubjectKind.key)
          Text("Everyone").tag(SubjectKind.everyone)
        }.pickerStyle(.segmented)
        switch subjectKind {
        case .device:
          Picker("Device", selection: $device) {
            Text("Choose a device").tag("")
            ForEach(devices) { device in
              Text(device.name).tag(device.id)
            }
          }
        case .group, .key:
          TextField(subjectKind == .group ? "Group id" : "Service key (SPKI)", text: $subjectText)
#if !os(tvOS)
            .textFieldStyle(.roundedBorder)
#endif
        case .everyone:
          EmptyView()
        }
        Picker("What", selection: $objectKind) {
          Text("Prefix").tag(ObjectKind.prefix)
          Text("Path").tag(ObjectKind.path)
          Text("Share").tag(ObjectKind.share)
        }.pickerStyle(.segmented)
        TextField(objectKind == .share ? "Resource id" : objectKind == .prefix ? "s3/" : "s3/read", text: $objectText)
#if !os(tvOS)
          .textFieldStyle(.roundedBorder)
#endif
        AsyncButton("Add Grant", systemImage: "plus") {
          guard let subject, let object else { return }
          try await hub.client.devices.addGrant(subject, object)
          objectText = ""
        }.disabled(subject == nil || object == nil)
      }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
  }
}

#Preview {
  SecurityView().test()
}
