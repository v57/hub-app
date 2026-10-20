//
//  Device Usage.swift
//  Hub
//
//  Created by Dmitry on 28.07.26.
//

import SwiftUI
import HubService

/// Live device data from `hub/devices/data`
enum DeviceUsage {
  struct LiveView: View {
    let data: DeviceData
    let capabilities: Capabilities?
    var memory: Float? {
      guard let used = data.memoryUsed, let total = capabilities?.memory, total > 0 else { return nil }
      return Float(Double(used) / Double(total))
    }
    var storage: Float? {
      guard let free = data.storageFree, let total = data.storageTotal, total > 0 else { return nil }
      return Float(1 - Double(free) / Double(total))
    }
    var body: some View {
      HStack(spacing: 16) {
        if let cpu = data.cpu {
          Gauge(value: Float(cpu), title: "CPU") {
            Image(systemName: "cpu")
          }
        }
        if let memory {
          Gauge(value: memory, title: "Memory") {
            Image(systemName: "memorychip")
          }
        }
        if let storage {
          Gauge(value: storage, title: data.storageFree.map { "\($0.formatted(.byteCount(style: .file))) free" } ?? "Storage") {
            Image(systemName: "internaldrive")
          }
        }
        if let battery = data.battery {
          Gauge(value: Float(battery), title: "\(Int(battery * 100))%") {
            Image(battery: Float(battery), charging: data.charging == true)
          }
        }
        if let network = data.network {
          VStack(spacing: 4) {
            Image(systemName: network.symbol).foregroundStyle(.blue).frame(width: 32, height: 32)
            Text(network.title).font(.caption2).secondary()
          }
        }
      }.monospacedDigit()
    }
  }

  struct Gauge<Icon: View>: View {
    let value: Float
    let title: String
    @ViewBuilder let icon: Icon
    var body: some View {
      VStack(spacing: 4) {
        CircleProgress(value: value) { icon }
        Text(title).font(.caption2).secondary().lineLimit(1)
      }
    }
  }

  struct CircleProgress<Icon: View>: View {
    let value: Float
    @ViewBuilder let icon: Icon
    var body: some View {
      ZStack {
        icon.foregroundStyle(.blue)
        Circle().stroke(.tint.opacity(0.2), lineWidth: 1)
        Circle().trim(from: 0, to: Double(min(max(value, 0), 1)))
          .rotation(.degrees(-90))
          .stroke(.blue.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
      }.frame(width: 32, height: 32)
    }
  }
}

extension DeviceData.Network {
  var symbol: String {
    switch self {
    case .wifi: "wifi"
    case .cellular: "antenna.radiowaves.left.and.right"
    case .ethernet: "cable.connector"
    case .other: "network"
    }
  }
  var title: LocalizedStringKey {
    switch self {
    case .wifi: "Wi-Fi"
    case .cellular: "Cellular"
    case .ethernet: "Ethernet"
    case .other: "Network"
    }
  }
}

#Preview {
  DeviceUsage.LiveView(
    data: DeviceData(cpu: 0.42, memoryUsed: 9_000_000_000, battery: 0.73, charging: true, network: .wifi, storageFree: 120_000_000_000, storageTotal: 512_000_000_000),
    capabilities: Capabilities(memory: 16_000_000_000)
  ).padding()
}
