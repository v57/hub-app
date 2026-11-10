//
//  Storage page.swift
//  Hub
//
//  This Device → Storage: shares part of this device's storage with one hub, up to a limit, and shows what's used and
//  free and whether the hub's devices can reach it.
//

#if canImport(S3ServerSwift) && canImport(ComponentKit)
import ComponentKit
import SwiftUI

struct StoragePage: View {
  @State private var storage = DeviceStorage.main
  @State private var hubs = Hubs.main
  @State private var chosenHub: Hub.ID?
  @State private var limit: Double = 1

  var body: some View {
    ScrollView {
      VStack(spacing: KitMetrics.gutter) {
        ShareCard(chosenHub: $chosenHub)
        SpaceCard(limit: $limit)
        if storage.isOn, let hub = storage.hub {
          KitSection("Files", meta: [hub.settings.name], systemImage: "folder", hue: .blue) {
            Text("The hub’s Files page lists this \(KitDevice.nameInSentence) among its storage places. Cameras’ clips and S3 RAID can use it too.")
              .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading).padding(8)
          } accessory: {
            Button("Open Files") { Navigator.main.open(hub, .files) }.buttonStyle(.kit).controlSize(.small)
          }
        }
        KitSection("While Hub Is Open", systemImage: "tree", hue: .green) {
          Text(Self.runsWhile).kitFont(.caption).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } accessory: {
          Button("Open Farm") { Navigator.main.route = .device(.farm) }.buttonStyle(.kit).controlSize(.small)
        }
      }
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
    }
    .kitPane(.content)
    .pageToolbar(String(localized: "Storage"), meta: meta, systemImage: "externaldrive", hue: .teal) { }
    .onAppear {
      limit = Double(max(storage.settings.limit, DeviceStorage.gigabyte) / DeviceStorage.gigabyte)
      chosenHub = storage.settings.hub ?? hubs.list.first(where: \.isConnected)?.id
    }
    .onChange(of: storage.settings.limit) { _, bytes in limit = Double(max(bytes, DeviceStorage.gigabyte) / DeviceStorage.gigabyte) }
  }

  private var meta: [String] {
    switch storage.phase {
    case .off, .failed: [String(localized: "Off")]
    case .starting: [String(localized: "Starting")]
    case .on: [storage.hub?.settings.name ?? "", StorageBackend.format(storage.usedBytes)].filter { !$0.isEmpty }
    }
  }

  private static var runsWhile: String {
#if os(iOS)
    String(localized: "iOS stops the storage shortly after Hub leaves the screen, and it starts again when you come back. To keep serving, leave Hub open: Farm keeps the screen awake, for example on an old iPhone or iPad on a charger.")
#else
    String(localized: "The storage runs while Hub is open. Farm keeps this Mac from sleeping.")
#endif
  }
}

/// On or off, and for which hub
private struct ShareCard: View {
  @Binding var chosenHub: Hub.ID?
  @State private var storage = DeviceStorage.main
  @State private var hubs = Hubs.main

  var body: some View {
    let connected = hubs.list.filter { $0.isConnected || $0.id == storage.settings.hub }
    KitSection("Share Storage", meta: [status], systemImage: "externaldrive", hue: .teal) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Your hub’s devices store files on this \(KitDevice.nameInSentence), like on any storage the hub has. Hub keeps them in a folder of its own, up to the limit below, and leaves them out of backups.")
          .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
        if connected.isEmpty {
          Text("Connect to a hub to share storage with it.").kitFont(.caption)
        } else {
          FormCard {
            FormRow("Hub", help: storage.isOn ? String(localized: "Turn it off to pick another hub") : nil, systemImage: "server.rack", hue: .gray) {
              KitPicker("Hub", selection: Binding { chosenHub ?? connected[0].id } set: { chosenHub = $0 }, options: connected.map { ($0.settings.name, $0.id) })
                .fixedSize()
                .disabled(storage.isOn)
            }
          }
        }
        if case .failed(let problem) = storage.phase {
          Label(problem, systemImage: "exclamationmark.triangle").kitFont(.caption).foregroundStyle(Hue.red.text)
        }
        if storage.isOn {
          if storage.isPublished {
            Label("Shared on Hub Network · port \(String(storage.port ?? 0))", systemImage: "checkmark.circle.fill")
              .kitFont(.caption).foregroundStyle(Hue.green.text)
          } else if let problem = storage.shareProblem {
            Label(problem, systemImage: "exclamationmark.triangle").kitFont(.caption).foregroundStyle(Hue.orange.text)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    } accessory: {
      Toggle("Share Storage", isOn: Binding { storage.isOn } set: { on in
        Task {
          if on, let hub = hubs.list.first(where: { $0.id == (chosenHub ?? connected.first?.id) }) {
            await storage.turnOn(hub: hub)
          } else if !on {
            await storage.turnOff()
          }
        }
      })
      .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
      .disabled(connected.isEmpty || storage.phase == .starting)
    }
  }

  private var status: String {
    switch storage.phase {
    case .off: String(localized: "off")
    case .starting: String(localized: "starting")
    case .on: storage.isPublished ? String(localized: "on Hub Network") : String(localized: "on")
    case .failed: String(localized: "didn’t start")
    }
  }
}

/// What's used, what's free on the device, and the limit
private struct SpaceCard: View {
  @Binding var limit: Double
  @State private var storage = DeviceStorage.main

  var body: some View {
    let limitBytes = Int64(limit) * DeviceStorage.gigabyte
    let largest = Double(storage.largestLimit / DeviceStorage.gigabyte)
    KitSection("Space", meta: [String(localized: "\(StorageBackend.format(storage.usedBytes)) of \(StorageBackend.format(limitBytes))")], systemImage: "internaldrive", hue: .teal) {
      VStack(alignment: .leading, spacing: 10) {
        KitProgressBar(value: limitBytes > 0 ? min(1, Double(storage.usedBytes) / Double(limitBytes)) : 0, hue: .teal)
        InfoLine(String(localized: "Used"), value: StorageBackend.format(storage.usedBytes))
        if let free = storage.volume.free {
          InfoLine(String(localized: "Free on This \(KitDevice.name)"), value: storage.volume.total.map { String(localized: "\(StorageBackend.format(free)) of \(StorageBackend.format($0))") } ?? StorageBackend.format(free))
        }
        HStack(spacing: 10) {
          Text("Limit").kitFont(.caption).frame(width: 52, alignment: .leading)
          KitSlider("Limit", value: $limit, in: 1...max(2, largest), step: 1, format: { "\(Int($0)) GB" }) { editing in
            if !editing { storage.setLimit(Int64(limit) * DeviceStorage.gigabyte) }
          }
          Text("\(Int(limit)) GB").kitFont(.caption).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
        Text("Uploads past the limit are refused, and so are uploads that would leave this \(KitDevice.nameInSentence) with less than 1 GB free. A lower limit keeps what’s stored.")
          .kitFont(.caption).fixedSize(horizontal: false, vertical: true)
      }
      .padding(8)
    }
  }
}

private struct InfoLine: View {
  let key: String
  let value: String
  init(_ key: String, value: String) {
    self.key = key
    self.value = value
  }
  var body: some View {
    HStack {
      Text(key).kitFont(.caption)
      Spacer()
      Text(value).kitFont(.caption).monospacedDigit()
    }
  }
}
#endif
