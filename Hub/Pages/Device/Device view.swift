//
//  Device view.swift
//  Hub
//
//  Created by Dmitry on 26.07.26.
//

import SwiftUI
import HubService

struct DeviceView: View {
  @Environment(Hub.self) private var hub
  @Environment(\.dismiss) private var dismiss
  @HubState(\.devices) private var devices
  @HubState(\.networkResources) private var resources
  let id: String
  @State private var data: DeviceData?
  @State private var isRenaming = false
  @State private var name = ""
  @State private var isRemoving = false
  @State private var isRevoking = false
  var device: Device? { devices.first { $0.id == id } }
  var body: some View {
    ScrollView {
      if let device {
        content(device)
      } else {
        Placeholder(image: "questionmark.circle", title: "Device not found") { }
      }
    }
  }
  @ViewBuilder
  func content(_ device: Device) -> some View {
    let isThisDevice = device.key == hub.client.device?.key.publicKey
    VStack(spacing: 16) {
      Placeholder(image: Device.symbol(platform: device.platform), title: LocalizedStringKey(device.name), isEnabled: device.online) {
        Label(device.statusText, systemImage: device.online ? "circle.fill" : "circle")
        if let os = device.os {
          Label([device.platform, os, device.arch].compactMap { $0 }.joined(separator: " "), systemImage: "info.circle")
        }
        if let parent = device.parent {
          Label("Runs in \(parent)", systemImage: "square.stack.3d.up")
        }
        if let network = device.network {
          Label(network == .online ? "Hub Network online" : "Hub Network offline", systemImage: network == .online ? "network" : "network.slash")
        }
        Label("Safety code \(DeviceKey.safetyCode(publicKey: device.key))", systemImage: "checkmark.shield")
        if isThisDevice {
          Label("This device", systemImage: "location.fill")
        }
      }
      if let data {
        DeviceUsage.LiveView(data: data, capabilities: device.capabilities)
      }
      if hub.require(permissions: "hub/device/rename") || hub.require(permissions: "hub/device/approve") {
        HStack {
          if !device.approved && hub.require(permissions: "hub/device/approve") {
            AsyncButton("Approve", systemImage: "checkmark") {
              try await hub.client.devices.approve(device.id)
            }
          }
          if hub.require(permissions: "hub/device/rename") {
            Button("Rename", systemImage: "pencil") {
              name = device.name
              isRenaming = true
            }
          }
          if !isThisDevice && hub.require(permissions: "hub/device/remove") {
            Button("Remove", systemImage: "minus.circle") {
              isRemoving = true
            }
          }
          if !isThisDevice && hub.require(permissions: "hub/device/revoke") {
            Button("Revoke", systemImage: "xmark.shield", role: .destructive) {
              isRevoking = true
            }
          }
        }.buttonStyle(.bordered)
      }
      if let capabilities = device.capabilities {
        CapabilitiesView(capabilities: capabilities)
      }
      let shares = shares(device)
      if device.overlay != nil || !shares.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Hub Network").sectionTitle()
          if let overlay = device.overlay {
            Label(overlay.address, systemImage: "network")
            Text(overlay.authority).code().lineLimit(1).truncationMode(.middle)
          }
          // A share keeps its resource id and authority when its service moves; the hub resolves it to the
          // overlay address of the service's current device
          ForEach(shares) { share in
            HStack(spacing: 10) {
              Image(systemName: "externaldrive.connected.to.line.below")
              VStack(alignment: .leading) {
                Text(share.shareName)
                Text(share.authority).code().lineLimit(1).truncationMode(.middle)
              }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Services").sectionTitle()
        if device.services.isEmpty {
          Text("No services").secondary()
        }
        ForEach(device.services) { service in
          HStack(spacing: 10) {
            (service.online ? OnlineStatus.online : .offline).view
            VStack(alignment: .leading) {
              Text(service.name ?? service.instance)
              HStack(spacing: 4) {
                if service.name != nil {
                  Text(service.instance)
                }
                Text(service.paths.count == 1 ? "1 api" : "\(service.paths.count) apis")
                Text(service.key.suffix(8)).code()
              }.secondary()
            }.lineLimit(1)
            Spacer(minLength: 0)
          }.padding(.vertical, 4)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(.horizontal)
      .task(id: device.online) {
        guard device.online, hub.require(permissions: "hub/devices/data") else { return }
        do {
          for try await data in hub.client.devices.data(device.id) {
            self.data = data
          }
        } catch { }
      }
      .alert("Rename device", isPresented: $isRenaming) {
        TextField("Name", text: $name)
        Button("Cancel", role: .cancel) { }
        Button("Rename") {
          let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty else { return }
          Task { try? await hub.client.devices.rename(device.id, to: name) }
        }
      }
      .confirmationDialog("Remove \(device.name)?", isPresented: $isRemoving, titleVisibility: .visible) {
        Button("Remove", role: .destructive) {
          Task {
            try? await hub.client.devices.remove(device.id)
            dismiss()
          }
        }
      } message: {
        Text("Its connections close. It can connect again and will wait for approval.")
      }
      .confirmationDialog("Revoke \(device.name)?", isPresented: $isRevoking, titleVisibility: .visible) {
        Button("Revoke device and its services", role: .destructive) {
          Task {
            try? await hub.client.devices.revoke(device.id)
            dismiss()
          }
        }
      } message: {
        Text(device.services.count == 1
             ? "For a lost or compromised device. Its connections close, its service key is revoked, its grants and Hub Network peers are removed, and it can never be approved again."
             : "For a lost or compromised device. Its connections close, its \(device.services.count) service keys are revoked, its grants and Hub Network peers are removed, and it can never be approved again.")
      }
  }
  /// Shares owned by the device's services, which its agent fronts
  func shares(_ device: Device) -> [HubNetworkResource] {
    let keys = Set(device.services.map(\.key))
    return resources.filter { keys.contains($0.ownerKey) }.sorted { $0.shareName < $1.shareName }
  }
  struct CapabilitiesView: View {
    let capabilities: Capabilities
    var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        Text("Capabilities").sectionTitle()
        if let model = capabilities.model {
          Label(model, systemImage: "info.circle")
        }
        if let cpu = capabilities.cpu {
          Label([cpu.model, cpu.cores.map { "\($0) cores" }].compactMap { $0 }.joined(separator: ", "), systemImage: "cpu")
        }
        if let memory = capabilities.memory {
          Label(memory.formatted(.byteCount(style: .memory)), systemImage: "memorychip")
        }
        if let gpu = capabilities.gpu {
          Label(gpu, systemImage: "display")
        }
        ForEach(capabilities.disks ?? [], id: \.name) { disk in
          Label("\(disk.name): \((disk.free ?? 0).formatted(.byteCount(style: .file))) free", systemImage: "internaldrive")
        }
        if let tools = capabilities.tools {
          let names = [tools.xcode.map { "Xcode \($0)" }, tools.swift.map { "Swift \($0)" },
                       tools.docker == true ? "Docker" : nil, tools.adb == true ? "adb" : nil].compactMap { $0 }
          if !names.isEmpty {
            Label(names.joined(separator: ", "), systemImage: "hammer")
          }
        }
        if let ssh = capabilities.ssh {
          Label("SSH on port \(ssh.port)", systemImage: "terminal")
        }
      }.secondary().frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension Device {
  var statusText: String {
    if revoked { return String(localized: "Revoked") }
    if !approved { return String(localized: "Waiting for approval") }
    if online { return String(localized: "Online") }
    if let lastSeen { return String(localized: "Last seen \(lastSeen.formatted(.relative(presentation: .named)))") }
    return String(localized: "Offline")
  }
}

#Preview {
  DeviceView(id: "").test().frame(maxWidth: .infinity)
}
