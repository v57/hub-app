//
//  App device.swift
//  Hub
//
//  The Hub app is one device and its reporter (Docs/Devices/device-layer.md, section 10).
//

import Foundation
import HubService
import Network
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import IOKit.ps
#endif

extension DeviceIdentity {
  /// The app's device key: Keychain `dev.v57.Hub.device.v1` in the access group shared with the packet tunnel
  /// extension. `nil` when the Keychain refuses (then the app connects without a device).
  @MainActor static let app: DeviceIdentity? = {
    let accessGroup = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String
    guard let key = try? DeviceKey.keychain(accessGroup: accessGroup?.isEmpty == false ? accessGroup : nil) else {
      return nil
    }
    return DeviceIdentity(key: key, name: AppDevice.name, platform: AppDevice.platform)
  }()
}

@MainActor
enum AppDevice {
  /// Device model plus the owner's choice of name where the system shares it
  static var name: String {
#if os(macOS)
    Host.current().localizedName ?? model
#elseif canImport(UIKit) && !os(watchOS)
    UIDevice.current.name
#else
    model
#endif
  }

  static var platform: String {
#if os(macOS) || targetEnvironment(macCatalyst)
    "macos"
#elseif os(visionOS)
    "visionos"
#elseif os(iOS)
    UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
#else
    DeviceIdentity.currentPlatform
#endif
  }

  /// Hardware identifier, `iPhone17,1` or `Mac15,9`
  static var model: String {
#if targetEnvironment(simulator)
    ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? sysctl("hw.machine") ?? "Simulator"
#elseif os(macOS)
    sysctl("hw.model") ?? "Mac"
#else
    sysctl("hw.machine") ?? "Apple device"
#endif
  }

  static var os: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
  }

  static var arch: String {
#if arch(arm64)
    "arm64"
#elseif arch(x86_64)
    "x64"
#else
    "other"
#endif
  }

  static func description() -> DeviceDescription {
    let storage = storage()
    return DeviceDescription(
      name: name, os: os, arch: arch,
      capabilities: Capabilities(
        cpu: .init(cores: ProcessInfo.processInfo.activeProcessorCount, model: sysctl("machdep.cpu.brand_string")),
        memory: Int64(ProcessInfo.processInfo.physicalMemory),
        disks: storage.map { [.init(name: "System", total: $0.total, free: $0.free)] },
        power: battery().level == nil ? .ac : .battery,
        model: model
      )
    )
  }

  static func data() -> DeviceData {
    let battery = battery()
    let storage = storage()
    return DeviceData(
      cpu: cpu.usage(),
      memoryUsed: memoryUsed(),
      battery: battery.level,
      charging: battery.charging,
      network: AppDevice.network.type,
      thermal: thermal,
      storageFree: storage?.free,
      storageTotal: storage?.total
    )
  }

  // MARK: Battery
  static func battery() -> (level: Double?, charging: Bool?) {
#if os(iOS) || os(visionOS)
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    // -1 and .unknown on the simulator and on devices without a battery
    guard device.batteryLevel >= 0 else { return (nil, nil) }
    return (Double(device.batteryLevel), device.batteryState == .charging || device.batteryState == .full)
#elseif os(macOS)
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil) }
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
            let current = description[kIOPSCurrentCapacityKey] as? Int,
            let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
      let charging = description[kIOPSIsChargingKey] as? Bool
        ?? (description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
      return (Double(current) / Double(max), charging)
    }
    return (nil, nil)
#else
    return (nil, nil)
#endif
  }

  // MARK: Storage
  static func storage() -> (free: Int64, total: Int64)? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
          let total = values.volumeTotalCapacity else { return nil }
    return (values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(total))
  }

  // MARK: Memory and CPU
  static func memoryUsed() -> Int64? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
    return pages * Int64(getpagesize())
  }

  static let cpu = CPULoad()
  final class CPULoad {
    private var previous: host_cpu_load_info?
    /// Share of busy ticks since the previous call, 0–1
    func usage() -> Double? {
      var info = host_cpu_load_info()
      var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
      }
      guard result == KERN_SUCCESS else { return nil }
      defer { previous = info }
      guard let previous else { return nil }
      func ticks(_ i: host_cpu_load_info) -> (busy: Double, total: Double) {
        let user = Double(i.cpu_ticks.0), system = Double(i.cpu_ticks.1), idle = Double(i.cpu_ticks.2), nice = Double(i.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
      }
      let now = ticks(info), before = ticks(previous)
      let total = now.total - before.total
      guard total > 0 else { return nil }
      return min(max((now.busy - before.busy) / total, 0), 1)
    }
  }

  static var thermal: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "nominal"
    }
  }

  // MARK: Network
  static let network = NetworkType()
  final class NetworkType: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    init() {
      monitor.pathUpdateHandler = { [weak self] path in
        guard let self else { return }
        lock.lock()
        self.path = path
        lock.unlock()
      }
      monitor.start(queue: DispatchQueue(label: "dev.v57.Hub.device.network"))
    }
    var type: DeviceData.Network? {
      lock.lock()
      defer { lock.unlock() }
      guard let path, path.status == .satisfied else { return nil }
      if path.usesInterfaceType(.wifi) { return .wifi }
      if path.usesInterfaceType(.cellular) { return .cellular }
      if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
      return .other
    }
  }

  private static func sysctl(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    let string = String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return string.isEmpty ? nil : string
  }
}
