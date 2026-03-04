//
//  Farm view.swift
//  Hub
//
//  Created by Linux on 31.10.25.
//

#if os(macOS) || os(iOS)
import SwiftUI
#if os(macOS)
import IOKit.ps
import IOKit.pwr_mgt
#elseif os(iOS)
import Combine
#endif

struct FarmView: View {
#if os(iOS)
  @State var blackOverlay: Bool = true
#else
  @State var blackOverlay: Bool = false
#endif
  @Bindable var farm = Farm.main
  var canStart: Bool {
    guard let battery = farm.battery else { return true }
    return battery.charging || battery.level >= farm.minimumBattery
  }
  var body: some View {
    VStack(spacing: 16) {
      if !farm.isRunning {
        Placeholder(image: "tree", title: "Farm", description: "Prevents your device from sleeping while enabled") { }
      }
      VStack {
        HStack {
          Slider(value: $farm.minimumBattery, in: 0...1, step: 0.05)
            .frame(maxWidth: 200)
          Image(battery: farm.minimumBattery, charging: false)
        }
        Text(text).secondary()
      }
#if os(iOS)
      HStack {
        VStack(alignment: .leading) {
          Text("Lower brightness")
          Text("Lowers brightness to minimum level until stops. Helps to save battery").secondary()
        }
        Spacer()
        Toggle("Lower brightness", isOn: $farm.lowerBrightness)
          .labelsHidden()
      }
      HStack {
        VStack(alignment: .leading) {
          Text("Black overlay")
          Text("Adds black screen, increasing battery life on OLED and XDR displays").secondary()
        }
        Spacer()
        Toggle("Black overlay", isOn: $blackOverlay)
          .labelsHidden()
      }
#endif
      if !canStart {
        VStack {
          Text("Start charging your device\nor change minimum battery level")
          if let battery = farm.battery {
            Text("Battery level is \(Int(battery.level * 100))%")
          }
        }.multilineTextAlignment(.center).foregroundStyle(.red).error().transition(.blurReplace)
      }
    }.safeAreaPadding(.horizontal)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .safeAreaInset(edge: .bottom) {
        Button(farm.isRunning ? "Stop" : "Start Farming") {
          withAnimation {
            farm.isRunning.toggle()
          }
        }.disabled(!canStart).buttonStyle(ActionButtonStyle()).padding()
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .toggleStyle(.switch)
      .overlay {
        if farm.isRunning {
#if os(iOS)
          Color.clear.toolbar(.hidden, for: .tabBar)
#endif
          Color.black.opacity(blackOverlay ? 1 : 0.001).onTapGesture {
            withAnimation {
              farm.isRunning = false
            }
          }.ignoresSafeArea()
        }
      }.disableSystemOverlay(farm.isRunning)
  }
  var text: LocalizedStringKey {
    if farm.minimumBattery == 0 {
      return "Run until turned off"
    } else if farm.minimumBattery == 1 {
      return "Run while charging"
    } else {
      return "Run while charging or battery level is above \(Int(farm.minimumBattery * 100))%"
    }
  }
}

//struct ActionButtonStyle: ButtonStyle {
//  func makeBody(configuration: Configuration) -> some View {
//    configuration.label
//  }
//}

extension View {
  func disableSystemOverlay(_ hidden: Bool) -> some View {
    #if os(iOS)
    statusBarHidden(hidden)
    #else
    self
    #endif
  }
}

extension Image {
  init(battery: Float, charging: Bool) {
    if charging {
      self.init(systemName: "battery.100percent.bolt")
    } else {
      switch battery {
      case ...0.1:
        self.init(systemName: "battery.0percent")
      case ...0.3:
        self.init(systemName: "battery.25percent")
      case ...0.6:
        self.init(systemName: "battery.50percent")
      case ...0.85:
        self.init(systemName: "battery.75percent")
      default:
        self.init(systemName: "battery.100percent")
      }
    }
  }
}

@Observable
class Farm {
  static let main = Farm()
  var battery: BatteryStatus? {
    didSet {
      guard battery != oldValue else { return }
      guard let battery else { return }
      guard isRunning else { return }
      guard !battery.charging && battery.level < minimumBattery else { return }
      isRunning = false
    }
  }
  var minimumBattery: Float = 0.8
  var isRunning = false {
    didSet {
      guard isRunning != oldValue else { return }
      preventSleep(enabled: isRunning)
      lowerBrightness(enabled: isRunning)
    }
  }
  var lowerBrightness: Bool = true
  
#if os(macOS)
  private var powerSourceRunLoopSource: CFRunLoopSource?
  private var sleepAssertionID: IOPMAssertionID = 0
#elseif os(iOS)
  private var brightness: CGFloat?
  weak var screen: UIScreen?
  private var powerTracking: AnyCancellable?
  private var farmTracking: AnyCancellable?
#endif
  
  init() {
#if canImport(UIKit)
    UIDevice.current.isBatteryMonitoringEnabled = true
#endif
    battery = batteryStatus()
    trackBattery()
#if os(iOS)
    farmTracking = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [unowned self] _ in
      isRunning = false
    }
#endif
  }
  
  struct BatteryStatus: Hashable {
    var level: Float
    var charging: Bool
  }
  
  private func batteryStatus() -> BatteryStatus? {
#if os(macOS)
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
    for ps in sources {
      let info = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as! [String: AnyObject]
      guard let capacity = info[kIOPSCurrentCapacityKey] as? Int else { continue }
      guard let max = info[kIOPSMaxCapacityKey] as? Int else { continue }
      return BatteryStatus(level: Float(capacity) / Float(max), charging: info[kIOPSPowerSourceStateKey] as? String != "Battery Power")
    }
    return nil
#elseif os(iOS)
    let state = UIDevice.current.batteryState
    return BatteryStatus(level: UIDevice.current.batteryLevel, charging: state == .charging || state == .full)
#endif
  }
  
  private func trackBattery() {
#if os(macOS)
    let context = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOPowerSourceCallbackType = { context in
      guard let context = context else { return }
      Unmanaged<Farm>.fromOpaque(context).takeUnretainedValue().updateBatteryStatus()
    }
    
    powerSourceRunLoopSource = IOPSNotificationCreateRunLoopSource(callback, context).takeRetainedValue()
    if let runLoopSource = powerSourceRunLoopSource {
      CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }
#elseif os(iOS)
    powerTracking = NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
      .merge(with: NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification))
      .sink { [unowned self] _ in
        updateBatteryStatus()
    }
#endif
  }
  
  private func stopTrackingBattery() {
#if os(macOS)
    if let runLoopSource = powerSourceRunLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }
#elseif os(iOS)
    NotificationCenter.default.removeObserver(self)
#endif
  }
  
  private func preventSleep(enabled: Bool) {
#if os(macOS)
    if enabled {
      // Prevent sleep - create assertion if not already active
      if sleepAssertionID == 0 {
        let result = IOPMAssertionCreateWithName(
          kIOPMAssertionTypeNoIdleSleep as CFString,
          IOPMAssertionLevel(kIOPMAssertionLevelOn),
          "Preventing system sleep" as CFString,
          &sleepAssertionID
        )
        if result != kIOReturnSuccess {
          print("Failed to create sleep assertion: \(result)")
        }
      }
    } else {
      // Allow sleep - release assertion if active
      if sleepAssertionID != 0 {
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
      }
    }
#elseif os(iOS)
    UIApplication.shared.isIdleTimerDisabled = enabled
#endif
  }
  
  private func updateBatteryStatus() {
    withAnimation {
      battery = batteryStatus()
    }
  }
  
  private func lowerBrightness(enabled: Bool) {
#if os(iOS)
    if enabled {
      if lowerBrightness {
        screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        if let screen {
          brightness = screen.brightness
          screen.brightness = 0
        }
      }
    } else if let brightness {
      screen?.brightness = brightness
    }
#endif
  }
}

#Preview {
  FarmView()
}
#endif
