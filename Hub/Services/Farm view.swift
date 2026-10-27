//
//  Farm view.swift
//  Hub
//
//  Created by Linux on 31.10.25.
//

#if !os(tvOS) && !os(visionOS)
import SwiftUI
import PlatformPower
#if os(iOS)
import Combine
#endif

struct FarmView: View {
#if os(iOS)
  @State var blackOverlay: Bool = true
#else
  @State var blackOverlay: Bool = false
#endif
  @State var statistics: Bool = true
  @Bindable var farm = Farm.main
  var canStart: Bool {
    guard let battery = farm.battery else { return true }
    return battery.isCharging || battery.level >= Double(farm.minimumBattery)
  }
  var body: some View {
    VStack(spacing: 16) {
      if !farm.isRunning {
        Placeholder(image: "tree", title: "Farm", description: "Prevents your device from sleeping while enabled") { }
        // The minimum battery level only means something on a device with a battery (not a Mac mini or a server).
        if farm.battery != nil {
          VStack {
            HStack {
              Slider(value: $farm.minimumBattery, in: 0...1, step: 0.10)
                .frame(maxWidth: 200)
              Image(battery: farm.minimumBattery, charging: false)
            }
            Text(text).secondary()
          }
        }
#if os(iOS)
        HStack {
          VStack(alignment: .leading) {
            Text("Lower brightness")
            Text("Lowers brightness to minimum level until stops. Helps to save battery").secondary()
          }
          Spacer(minLength: 0)
          Toggle("Lower brightness", isOn: $farm.lowerBrightness)
            .labelsHidden()
        }
        HStack {
          VStack(alignment: .leading) {
            Text("Black overlay")
            Text("Adds black screen, increasing battery life on OLED and XDR displays").secondary()
          }
          Spacer(minLength: 0)
          Toggle("Black overlay", isOn: $blackOverlay)
            .labelsHidden()
        }
#endif
        HStack {
          VStack(alignment: .leading) {
            Text("Show Activity")
            Text("Will display requests when they happen").secondary()
          }
          Spacer(minLength: 0)
          Toggle("Show Activity", isOn: $statistics)
            .labelsHidden()
        }
      }
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
          Color.black.opacity(blackOverlay ? 1 : 0.001).onTapGesture {
            withAnimation {
              farm.isRunning = false
            }
          }.ignoresSafeArea()
        }
      }.overlay(alignment: farm.isRunning ? .center : .topTrailing) {
        if statistics {
          StatisticsView().padding().task(id: farm.lowerBrightness && Statistics.main.hasActivity && farm.isRunning) {
            guard farm.lowerBrightness && farm.isRunning else { return }
            do {
              if !Statistics.main.hasActivity {
                try await Task.sleep(for: .seconds(1))
              }
              farm.lowerBrightness(enabled: !Statistics.main.hasActivity)
            } catch { }
          }
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
    statusBarHidden(hidden).toolbar(.hidden, for: .navigationBar)
      .toolbar(.hidden, for: .tabBar)
    #else
    self
    #endif
  }
}

@Observable
@MainActor class Farm {
  static let main = Farm()
  var battery: Battery? {
    didSet {
      guard battery != oldValue else { return }
      guard let battery else { return }
      guard isRunning else { return }
      guard !battery.isCharging && battery.level < Double(minimumBattery) else { return }
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
  
  /// Keeps the device awake while farming
  private var awake: SleepAssertion?
  private var batteryObservation: BatteryObservation?
#if os(iOS)
  private var brightness: CGFloat?
  weak var screen: UIScreen?
  private var farmTracking: AnyCancellable?
#endif
  
  init() {
    battery = Battery.current
    batteryObservation = Battery.observe { [weak self] battery in
      withAnimation { self?.battery = battery }
    }
#if os(iOS)
    farmTracking = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [unowned self] _ in
      isRunning = false
    }
#endif
  }
  
  private func preventSleep(enabled: Bool) {
    if enabled {
      if awake == nil { awake = SleepAssertion(.idleSleep, reason: "Hub is farming: running services for your hubs") }
    } else {
      awake?.release()
      awake = nil
    }
  }
  
  func lowerBrightness(enabled: Bool) {
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
