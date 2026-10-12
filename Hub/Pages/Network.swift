//
//  Network.swift
//  Hub
//
//  Created by Dmitry on 26.07.26.
//

import SwiftUI

struct NetworkStatus {
  var vpn: String? = "MacBook Pro"
  var shareVPN = false
  var sharePorts: Set<Int> = [8080, 25565]
}

struct HubDevice: Identifiable {
  let id = UUID()
  let name: String
  var net = true
  var online: OnlineStatus = .online
  var battery: Float? = nil
  var charging = false
}

struct NetworkView: View {
  @State var devices: [HubDevice] = [
    HubDevice(name: "MacBook Pro", net: true, battery: 1.0, charging: true),
    HubDevice(name: "MacBook Air", net: false, battery: 0.73),
    HubDevice(name: "MacBook Intel", net: false, battery: 0.19),
    HubDevice(name: "Windows PC", net: false),
    HubDevice(name: "iPhone", net: true, online: .offline),
    HubDevice(name: "iPad", net: true, online: .offline),
  ]
  @State var status = NetworkStatus()
  var body: some View {
    ScrollView {
      VStack {
        Status(devices: devices, status: $status)
        LazyVGrid(minWidth: 180) {
          ForEach(devices) { device in
            DeviceView(device: device, status: $status)
          }
        }
      }.padding()
    }
  }
  struct Status: View {
    let devices: [HubDevice]
    @Binding var status: NetworkStatus
    var body: some View {
      Placeholder(image: "network", title: "Hub Network") {
        if let vpn = status.vpn, let device = devices.first {
          Label("Accessing internet through: \(device.name)", systemImage: "network")
            .foregroundStyle(.secondary, .blue)
        }
        Toggle("Allow others to use this mac as VPN", isOn: $status.shareVPN)
      }
    }
  }
  struct DeviceView: View {
    let device: HubDevice
    @Binding var status: NetworkStatus
    var isOnline: Bool { device.online == .online }
    var isUsingVpn: Bool { status.vpn == device.name }
    var body: some View {
      Button {
        if isOnline {
          withAnimation {
            if status.vpn != device.name {
              status.vpn = device.name
            } else {
              status.vpn = nil
            }
          }
        }
      } label: {
        VStack(alignment: .leading) {
          HStack(spacing: 10) {
            device.online.view
            Text(device.name).frame(maxWidth: .infinity, alignment: .leading)
            if let battery = device.battery {
              Image(battery: battery, charging: device.charging)
                .secondary()
            }
          }.lineLimit(1)
          Image(systemName: device.net ? "network" : "network.slash")
            .foregroundStyle(isUsingVpn ? Color.blue : device.net && isOnline ? Color.secondary : Color.secondary.opacity(0.3))
        }.foregroundStyle(isOnline ? .primary : .tertiary)
          .padding(10).frame(maxWidth: .infinity, alignment: .leading)
          .overlay {
            if status.vpn == device.name {
              RoundedRectangle(cornerRadius: 16).strokeBorder(.blue)
            }
          }
          .hoverEffect(in: .rounded(16))
      }.buttonStyle(.environment)
    }
  }
}

#Preview {
  NetworkView().frame(maxWidth: .infinity)
    .test()
}
