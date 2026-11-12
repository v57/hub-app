//
//  Camera screen.swift
//  Hub
//
//  The iPhone or iPad that is the camera: over the app while its cameras run, black (an OLED screen draws nothing)
//  with its state at a glance (live, watching, the motion level, network, power, heat, where clips go) and Stop. It
//  turns fully black after 30 s and comes back on a touch. iOS stops the camera when Hub goes to the background, so
//  this keeps Hub in front with the screen dark.
//

#if os(iOS) && canImport(ComponentKit) && canImport(PlatformCamera)
import SwiftUI
import ComponentKit
import PlatformCamera
import PlatformPower

struct CameraScreen: View {
  @State private var camera = SecurityCamera.main
  @State private var lastTouch = Date()
  @State private var showsPreview = false
  @State private var renderer: CameraVideoRenderer?

  private static let blackAfter: Double = 30

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let isBlack = context.date.timeIntervalSince(lastTouch) > Self.blackAfter
      ZStack {
        Color.black.ignoresSafeArea()
        if !isBlack {
          content.transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.6), value: isBlack)
    }
    .contentShape(Rectangle())
    .onTapGesture { lastTouch = Date() }
    .environment(\.colorScheme, .dark)
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .onAppear {
      lastTouch = Date()
      UIApplication.shared.isIdleTimerDisabled = true
    }
  }

  private var units: [SecurityCamera.Unit] { camera.orderedUnits }

  private var content: some View {
    let units = units
    let watching = units.reduce(0) { $0 + $1.viewers }
    let motion = units.contains { $0.motion.isActive }
    return VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 8) {
        VideoChip(title: camera.interruption == nil ? String(localized: "LIVE") : String(localized: "PAUSED"), tone: camera.interruption == nil ? .live : .plain)
        if watching > 0 { Text("\(watching) watching").kitFont(.callout).foregroundStyle(.white.opacity(0.7)) }
        if motion { VideoChip(title: String(localized: "Motion"), systemImage: "figure.walk.motion", tone: .motion) }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(units.count == 1 ? String(units[0].shareName.dropFirst(HubCamera.sharePrefix.count)) : String(localized: "\(units.count) Cameras"))
          .font(.system(size: 34, weight: .bold))
        Text("Camera on for \(camera.hub?.settings.name ?? String(localized: "the hub"))").font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
      }
      ForEach(units) { unit in
        let threshold = MotionDetector(sensitivity: camera.settings.cameras.first { $0.id == unit.id }?.sensitivity ?? 0.5).areaThreshold
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(units.count == 1 ? String(localized: "Motion") : String(unit.shareName.dropFirst(HubCamera.sharePrefix.count)))
            Spacer()
            Text(unit.motion.isActive ? "recording" : "nothing moving")
          }
          .kitFont(.caption).foregroundStyle(.white.opacity(0.6))
          LevelMeter(level: CameraFormat.meter(unit.motion.level), threshold: CameraFormat.meter(threshold))
        }
      }
      if showsPreview, let renderer {
        CameraVideoView(renderer: renderer)
          .aspectRatio(16 / 9, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .opacity(0.6)
      }
      VStack(alignment: .leading, spacing: 10) {
        status("network", "\(camera.hub?.settings.name ?? "Hub") · " + (units.allSatisfy(\.isPublished) ? "Hub Network" : units.compactMap(\.shareProblem).first ?? String(localized: "not shared yet")))
        if let battery = Battery.current {
          status(battery.isCharging ? "battery.100.bolt" : "battery.50", battery.isCharging
            ? String(localized: "\(Int((battery.level * 100).rounded()))% · charging")
            : String(localized: "\(Int((battery.level * 100).rounded()))% · on battery"))
        }
        status("mic.slash", String(localized: "Microphone off"))
        status("thermometer.medium", camera.budget.pressure == .nominal ? String(localized: "Normal temperature") : String(localized: "\(camera.budget.pressure.title) pressure: iOS may slow the camera"))
        status("externaldrive", camera.settings.storage.target == .hub ? String(localized: "Clips to \(camera.hub?.settings.name ?? String(localized: "the hub"))’s storage") : String(localized: "Clips on this \(KitDevice.nameInSentence)"))
        if let interruption = camera.interruption { status("pause.circle", interruption) }
      }
      Spacer(minLength: 0)
      HStack(spacing: 10) {
        Button(showsPreview ? "Hide Preview" : "Preview") { togglePreview() }.buttonStyle(.kit)
        Button("Back to Hub") { camera.showsScreen = false }.buttonStyle(.kit)
        Spacer()
        Button("Stop Camera") { Task { await camera.turnOff() } }.buttonStyle(.kitPrimary)
      }
      Text("The screen turns black in \(Int(Self.blackAfter)) s. Touch to see this again.")
        .kitFont(.caption).foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
    .frame(maxWidth: 560)
  }

  private func status(_ systemImage: String, _ text: String) -> some View {
    Label(text, systemImage: systemImage).kitFont(.callout).foregroundStyle(.white.opacity(0.75))
  }

  /// The first camera's picture, dimmed, while asked for
  private func togglePreview() {
    showsPreview.toggle()
    lastTouch = Date()
    guard showsPreview, let unit = units.first else {
      renderer = nil
      return
    }
    let renderer = CameraVideoRenderer()
    self.renderer = renderer
    let stop = unit.engine.watch { renderer.enqueue($0) }
    Task {
      while showsPreview, camera.units[unit.id] != nil { try? await Task.sleep(for: .seconds(1)) }
      stop()
    }
  }
}
#endif
