//
//  Devices.swift
//  Hub
//
//  Devices of this hub: presence, services, approval and live data (hub/devices).
//

import SwiftUI
import HubService

struct DevicesView: View {
  @Environment(Hub.self) private var hub
  @HubState(\.devices) private var devices
  @HubState(\.pendingDevices) private var pending
  @State private var selected: DeviceLink?
  /// Approved devices; pending ones are listed above them
  var sorted: [Device] {
    devices.filter { $0.approved && !$0.revoked }.sorted {
      ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased())
    }
  }
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Placeholder(image: "macbook.and.iphone", title: "Devices", description: """
          Every computer, phone and container connected to this Hub
          A device signs its services, so revoking it disconnects all of them
          """) {
          if let device = hub.client.device {
            Label("This device's safety code: \(device.key.safetyCode)", systemImage: "checkmark.shield")
          }
        }
        if !pending.isEmpty && hub.require(permissions: "hub/device/approve") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for approval").sectionTitle()
            ForEach(pending) { device in
              PendingDeviceView(device: device)
            }
          }
        }
        LazyVGrid(minWidth: 200) {
          ForEach(sorted) { device in
            Button {
              selected = DeviceLink(id: device.id)
            } label: {
              DeviceCell(device: device, isThisDevice: device.key == hub.client.device?.key.publicKey)
            }.buttonStyle(.environment)
          }
        }
        if devices.isEmpty {
          Text("No devices yet. Apps and services with device support appear here when they connect.").secondary()
        }
      }.padding(.horizontal, 4)
    }.navigationDestination(item: $selected) { link in
      DeviceView(id: link.id).hub(hub)
    }
  }
}

struct DeviceLink: Hashable, Identifiable {
  let id: String
}

struct PendingDeviceView: View {
  @Environment(Hub.self) private var hub
  let device: PendingDevice
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: Device.symbol(platform: device.platform)).font(.title2).frame(width: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(device.name ?? device.id)
        HStack(spacing: 4) {
          Text("Safety code")
          Text(device.safetyCode).monospacedDigit().foregroundStyle(.primary)
          if let parent = device.parent {
            Text("• in \(parent)")
          }
        }.secondary()
      }.lineLimit(1)
      Spacer(minLength: 0)
      AsyncButton("Approve") {
        try await hub.client.devices.approve(device.id)
      }
    }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
  }
}

struct DeviceCell: View {
  @Environment(Hub.self) private var hub
  let device: Device
  let isThisDevice: Bool
  @State private var data: DeviceData?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        (device.online ? OnlineStatus.online : .offline).view
        Text(device.name).frame(maxWidth: .infinity, alignment: .leading)
        if let battery = data?.battery {
          Image(battery: Float(battery), charging: data?.charging == true).secondary()
        }
      }.lineLimit(1)
      HStack(spacing: 6) {
        Image(systemName: Device.symbol(platform: device.platform))
        if let network = device.network {
          Image(systemName: network == .online ? "network" : "network.slash")
        }
        Text(device.subtitle(isThisDevice: isThisDevice)).lineLimit(1)
      }.secondary()
    }.foregroundStyle(device.online ? .primary : .tertiary)
      .padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .hoverEffect(in: .rounded(16))
      .task(id: device.online) {
        guard device.online, hub.require(permissions: "hub/devices/data") else { return }
        do {
          for try await data in hub.client.devices.data(device.id) {
            self.data = data
          }
        } catch { }
      }
  }
}

extension Device {
  static func symbol(platform: String?) -> String {
    switch platform {
    case "macos": "macbook"
    case "ios": "iphone"
    case "ipados": "ipad"
    case "visionos": "visionpro"
    case "tvos": "appletv"
    case "watchos": "applewatch"
    case "linux": "server.rack"
    case "windows": "pc"
    case "android": "smartphone"
    default: "desktopcomputer"
    }
  }
  func subtitle(isThisDevice: Bool) -> String {
    var parts = [String]()
    if isThisDevice { parts.append(String(localized: "This device")) }
    if !approved { parts.append(String(localized: "Pending")) }
    let online = services.filter(\.online).count
    parts.append(services.count == 1 ? String(localized: "1 service") : String(localized: "\(services.count) services"))
    if online > 0 && online < services.count { parts.append(String(localized: "\(online) online")) }
    if !self.online, let lastSeen {
      parts.append(lastSeen.formatted(.relative(presentation: .named)))
    }
    return parts.joined(separator: " • ")
  }
}

#Preview {
  DevicesView().test()
}
