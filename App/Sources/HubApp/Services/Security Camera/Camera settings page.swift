//
//  Camera settings page.swift
//  Hub
//
//  This device as the hub's camera: on or off for the hub, each of its cameras (lenses) on or off as its own camera
//  named by its place, and for the one selected its preview with the motion zone, the live motion level against the
//  sensitivity, its video (sizes, frame rates and codecs it can't do now greyed, with why), what that costs in data and
//  storage, how much it adjusts its picture against the system's own budget, when it records (a Mac: only while
//  nobody is using it), where clips go, and its password.
//  On a Mac two columns; on iPhone one, with Picture and Power and Expected Usage pushed.
//

#if canImport(ComponentKit) && canImport(PlatformCamera)
import SwiftUI
import ComponentKit
import PlatformCamera
import PlatformPower

struct CameraSettingsPage: View {
  /// Back to the grid, where the page opens in place
  var back: (() -> Void)?
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  @State private var camera = SecurityCamera.main
  @State private var selection: String?
  @State private var pushed: Push?
  /// The motion zone being edited on the preview
  @State private var zone: MotionDetector.Zone?

  enum Push: Hashable {
    case picture, usage
  }

  var body: some View {
    let setups = setups
    let selected = setups.first { $0.id == selection } ?? setups.first { $0.isOn } ?? setups.first
    ScrollView {
      Group {
        if let selected {
          if idiom == .phone {
            VStack(spacing: KitMetrics.gutter) {
              CameraBanners()
              master
              CameraPreviewCard(setup: selected, editing: $zone)
              CamerasCard(setups: setups, selected: selected.id) { selection = $0 }
              VideoCard(setup: selected)
              MotionCard(setup: selected) { zone = selected.zone ?? CameraPreviewCard.suggested }
              KitSection("More", systemImage: "ellipsis", hue: .gray) {
                SidebarRow("Picture and Power", subtitle: [selected.profile?.title ?? "Custom", "budget"].joined(separator: " · "), systemImage: "bolt") {
                  KitPushChevron()
                }
                .action { pushed = .picture }
                SidebarRow("Expected Usage", subtitle: usageLine(selected), systemImage: "chart.bar") {
                  KitPushChevron()
                }
                .action { pushed = .usage }
              }
              ClipsCard()
              AccessCard(setup: selected)
              AppleHomeCard()
            }
          } else {
            VStack(spacing: KitMetrics.gutter) {
              CameraBanners()
              HStack(alignment: .top, spacing: KitMetrics.gutter * 1.5) {
                VStack(spacing: KitMetrics.gutter) {
                  CameraPreviewCard(setup: selected, editing: $zone)
                  MotionCard(setup: selected) { zone = selected.zone ?? CameraPreviewCard.suggested }
                  UsageCard(setup: selected)
                  PictureCard(setup: selected)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: KitMetrics.gutter) {
                  master
                  CamerasCard(setups: setups, selected: selected.id) { selection = $0 }
                  if UserPresence.isSupported {
                    WhenToRecordCard(setup: selected)
                  }
                  VideoCard(setup: selected)
                  ClipsCard()
                  AccessCard(setup: selected)
                  AppleHomeCard()
                }
                .frame(maxWidth: .infinity)
              }
            }
          }
        } else {
          EmptyState(systemImage: "video.slash", title: "No Camera Found", message: "This \(KitDevice.nameInSentence) has no camera Hub can use.") {}
            .padding(.top, 60)
        }
      }
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
    }
    .kitPane(.content)
    .cameraToolbar("This \(KitDevice.name) as a Camera", meta: meta, systemImage: KitDevice.name == "Mac" ? "laptopcomputer" : "iphone", hue: .indigo, back: back) {
      ToolGroup {
        if isOnHere {
          Button("Turn Off", systemImage: "stop.fill") { Task { await camera.turnOff() } }
        } else {
          Button("Turn On", systemImage: "play.fill") { Task { await turnOn() } }
            .disabled(camera.phase == .starting)
        }
#if os(iOS)
        if isOnHere {
          Button("Camera Screen", systemImage: "moon") { camera.showsScreen = true }
        }
#endif
      }
    }
    .navigationDestination(item: $pushed) { push in
      if let selected {
        ScrollView {
          VStack(spacing: KitMetrics.gutter) {
            switch push {
            case .picture: PictureCard(setup: selected)
            case .usage: UsageCard(setup: selected)
            }
          }
          .padding(KitMetrics.gutter)
        }
        .kitPane(.content)
        .pageToolbar(push == .picture ? "Picture and Power" : "Expected Usage", meta: [selected.place], systemImage: push == .picture ? "bolt" : "chart.bar", hue: .indigo) {}
        .hub(hub)
      }
    }
  }

  private var isOnHere: Bool { camera.isOn && camera.hubID == hub.id }

  /// Every lens of this device, saved or not
  private var setups: [CameraSetup] {
    camera.devices.map { camera.setup(for: $0) }
  }

  private var meta: [String] {
    guard isOnHere else { return [camera.isOn ? "on for \(camera.hub?.settings.name ?? "another hub")" : "Off"] }
    let on = camera.orderedUnits.count
    var parts = [on == 1 ? "1 camera on" : "\(on) cameras on", "for \(hub.settings.name)"]
    let watching = camera.orderedUnits.reduce(0) { $0 + $1.viewers }
    if watching > 0 { parts.append("\(watching) watching") }
    return parts
  }

  private func turnOn() async {
    await camera.turnOn(hub: hub)
#if os(iOS)
    if camera.phase == .on { camera.showsScreen = true }
#endif
  }

  private func usageLine(_ setup: CameraSetup) -> String {
    let rate = Double(setup.video.effectiveBitrate) / 8
    return "\(CameraFormat.rate(rate)) per viewer · \(CameraFormat.bytes(rate * camera.clipSecondsPerDay(setup.id))) of clips a day"
  }

  /// On or off for this hub, and why it can't be
  @ViewBuilder private var master: some View {
    KitSection("Camera", meta: masterMeta, systemImage: "web.camera", hue: isOnHere ? .green : .gray, status: camera.phase == .starting ? .working : .idle) {
      SidebarRow("Use as a Security Camera", subtitle: masterLine, systemImage: "video", hue: isOnHere ? .green : .gray) {
        Toggle("Use as a Security Camera", isOn: Binding { isOnHere } set: { on in
          Task { on ? await turnOn() : await camera.turnOff() }
        })
        .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
        .disabled(camera.phase == .starting)
      }
      if case .failed(let message) = camera.phase {
        Text(message).kitFont(.caption).foregroundStyle(Hue.red.text).padding(8)
      }
      if let interruption = camera.interruption, isOnHere {
        Label(interruption, systemImage: "pause.circle").kitFont(.caption).foregroundStyle(Hue.orange.text).padding(8)
      }
    }
  }

  private var masterMeta: [String] {
    if isOnHere { return ["On", "for \(hub.settings.name)"] }
    if camera.isOn, let other = camera.hub { return ["On for \(other.settings.name)"] }
    return ["Off"]
  }

  private var masterLine: String {
    if camera.isOn, camera.hubID != hub.id, let other = camera.hub {
      return "On for \(other.settings.name). Turning it on here moves it."
    }
    var line = "Watches for motion and records clips. Only \(hub.settings.name)’s devices on Hub Network with the password can watch."
    if KitDevice.name != "Mac" { line += " Hub has to stay open." }
    return line
  }
}

// MARK: - Preview

/// The selected camera's own picture, with its motion zone to edit
private struct CameraPreviewCard: View {
  let setup: CameraSetup
  @Binding var editing: MotionDetector.Zone?
  @State private var camera = SecurityCamera.main
  @State private var renderer: CameraVideoRenderer?

  var body: some View {
    let unit = camera.units[setup.id]
    let aspect = CGFloat(setup.video.width) / CGFloat(setup.video.height)
    ZStack {
      Color.black
      if let renderer, unit != nil {
        CameraVideoView(renderer: renderer)
      } else {
        VStack(spacing: 6) {
          Image(systemName: "video.slash").font(.title2)
          Text(setup.isOn ? "Turn the camera on to see \(setup.place)." : "\(setup.place) is off.").kitFont(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
      }
      PictureSpace(aspect: aspect) {
        ZStack {
          if let box = unit?.motion.box, unit?.motion.isActive == true {
            MotionBox(box: box)
          }
          if editing != nil || setup.zone != nil {
            ZoneEditor(zone: Binding { editing ?? setup.zone ?? .all } set: { editing = $0 }, isEditing: editing != nil)
          }
        }
      }
      VStack {
        HStack(spacing: 6) {
          if unit != nil { VideoChip(title: "LIVE", tone: .live) }
          VideoChip(title: setup.place)
          Spacer()
          if editing != nil || setup.zone != nil { VideoChip(title: "Zone", systemImage: "rectangle.dashed") }
          if unit?.motion.isActive == true { VideoChip(title: "Motion", systemImage: "figure.walk.motion", tone: .motion) }
        }
        Spacer()
        HStack(spacing: 6) {
          VideoChip(title: camera.devices.first { $0.id == setup.device }?.name ?? "Camera", systemImage: "camera")
          Spacer()
          VideoChip(title: setup.video.title)
        }
      }
      .padding(8)
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radiusXL))
    .overlay(alignment: .bottom) {
      if editing != nil {
        HStack(spacing: 6) {
          Button("Whole Picture") { editing = nil; save(nil) }.buttonStyle(.kit).controlSize(.small)
          Button("Cancel") { editing = nil }.buttonStyle(.kit).controlSize(.small)
          Button("Save Zone") { save(editing); editing = nil }.buttonStyle(.kitPrimary).controlSize(.small)
        }
        .padding(.bottom, 36)
      }
    }
    .task(id: unit.map(ObjectIdentifier.init)) {
      // The engine's own encoded frames, from its next keyframe, while the card shows
      guard let unit else {
        renderer = nil
        return
      }
      let renderer = CameraVideoRenderer()
      self.renderer = renderer
      let stop = unit.engine.watch { renderer.enqueue($0) }
      await withTaskCancellationHandler {
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
      } onCancel: {
        stop()
      }
    }
    .onChange(of: setup.id) { editing = nil }
  }

  static let suggested = MotionDetector.Zone(x: 0.15, y: 0.15, width: 0.7, height: 0.7)

  private func save(_ zone: MotionDetector.Zone?) {
    var setup = setup
    // A zone that is the whole picture is none
    setup.zone = zone.flatMap { $0.width > 0.98 && $0.height > 0.98 ? nil : $0 }
    camera.update(setup)
  }
}

// MARK: - Motion

private struct MotionCard: View {
  let setup: CameraSetup
  let editZone: () -> Void
  @State private var camera = SecurityCamera.main

  var body: some View {
    let unit = camera.units[setup.id]
    let threshold = MotionDetector(sensitivity: setup.sensitivity).areaThreshold
    let level = unit?.motion.level ?? 0
    KitSection("Motion", meta: [setup.place, unit == nil ? "off" : unit?.motion.isActive == true ? "motion now" : "nothing moving"], systemImage: "figure.walk.motion", hue: .orange) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Text("Live level").kitFont(.caption).frame(width: 84, alignment: .leading)
          LevelMeter(level: CameraFormat.meter(level), threshold: CameraFormat.meter(threshold))
          Text(String(format: "%.1f%%", level * 100)).kitFont(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        HStack(spacing: 10) {
          Text("Sensitivity").kitFont(.caption).frame(width: 84, alignment: .leading)
          KitSlider("Sensitivity", value: Binding { setup.sensitivity } set: { value in
            var setup = setup
            setup.sensitivity = value
            camera.update(setup)
          }, in: 0...1, step: 0.05)
          Text("\(Int((setup.sensitivity * 100).rounded()))%").kitFont(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        Text("Motion past the line records a clip: \(String(format: "%.1f%%", threshold * 100)) of \(setup.zone == nil ? "the picture" : "the zone") changing. \(setup.zone == nil ? "All of the picture counts." : "Only motion inside the zone counts.")")
          .kitFont(.caption)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    } accessory: {
      Button(setup.zone != nil ? "Edit Zone…" : "Add Zone…") { editZone() }
        .buttonStyle(.kit).controlSize(.small)
    }
  }

}

// MARK: - Cameras

/// Each lens: on or off, as its own camera on the hub
private struct CamerasCard: View {
  let setups: [CameraSetup]
  let selected: String
  let select: (String) -> Void
  @State private var camera = SecurityCamera.main

  var body: some View {
    let on = setups.filter(\.isOn).count
    KitSection("Cameras", meta: ["\(on) of \(setups.count) on", "each is its own camera"], systemImage: "camera", hue: .indigo) {
      ForEach(setups) { setup in
        let device = camera.devices.first { $0.id == setup.device }
        let reason = device.flatMap { camera.reasonCantTurnOn($0) }
        SidebarRow(setup.place, subtitle: subtitle(setup, device: device, reason: reason), systemImage: symbol(device), hue: setup.isOn ? .indigo : nil) {
          Toggle(setup.place, isOn: Binding { setup.isOn } set: { on in
            var setup = setup
            setup.isOn = on
            camera.update(setup)
          })
          .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
          .disabled(!setup.isOn && reason != nil)
        }
        .isCurrent(setup.id == selected)
        .action { select(setup.id) }
      }
      Text(footer).kitFont(.caption).padding(8)
    }
  }

  private func subtitle(_ setup: CameraSetup, device: CameraDevice?, reason: String?) -> String {
    let lens = device?.name ?? "Camera"
    if setup.isOn { return "\(lens) · \(setup.video.title)" }
    if let reason { return "\(lens) · \(reason)" }
    let caps = CameraCapabilitiesCache.get(setup.device, together: 1)
    let top = caps.sizes.last.map { "up to \($0.height)p, \($0.maxFPS) fps" } ?? "off"
    return "\(lens) · off · \(top)"
  }

  private func symbol(_ device: CameraDevice?) -> String {
    switch device?.position {
    case .front: "person.crop.square"
    case .external: "web.camera"
    default: "camera"
    }
  }

  private var footer: String {
    let count = CameraRig.maximumCameras
    let most = count <= 1 ? "one camera at a time" : "\(count) cameras at once"
    return "This \(KitDevice.nameInSentence) runs \(most). Each camera has its own name, video, motion and clips; more of them on means more heat and more data."
  }
}

// MARK: - Video

private struct VideoCard: View {
  let setup: CameraSetup
  @State private var camera = SecurityCamera.main
  @State private var place = ""
  /// What each size and frame rate would cost with the other cameras on (iPhone and iPad with several on)
  @State private var costs: [String: Double] = [:]

  var body: some View {
    let together = max(1, Set(camera.settings.cameras.filter(\.isOn).map(\.device) + (setup.isOn ? [setup.device] : [])).count)
    let caps = CameraCapabilitiesCache.get(setup.device, together: together)
    let alone = CameraCapabilitiesCache.get(setup.device, together: 1)
    let top = caps.sizes.last
    KitSection("Video", meta: [setup.place, camera.devices.first { $0.id == setup.device }?.name ?? ""], systemImage: "camera.aperture", hue: .blue) {
      FormCard {
        FormRow("Name", help: "The place it watches: its name on \(camera.hub?.settings.name ?? "the hub")", systemImage: "mappin") {
          TextField("Front Door", text: $place)
            .kitField().frame(maxWidth: 200)
            .onSubmit { rename() }
        }
        FormRow("Resolution", help: top.map { "Up to \($0.height)p" + (together > 1 ? " with \(together) cameras on" : " on this camera") }, systemImage: "rectangle.expand.vertical") {
          KitPicker("Resolution", selection: binding(\.video.height), segments: CameraVideo.heights.map { height in
            let reason = sizeReason(height, caps: caps, alone: alone)
            return KitSegment(reason.map { "\(height)p — \($0)" } ?? "\(height)p", value: height, isEnabled: reason == nil)
          })
          .fixedSize()
        }
        FormRow("Frame Rate", help: caps.maxFPS(height: setup.video.height).map { "Up to \($0) fps at \(setup.video.height)p" }, systemImage: "speedometer") {
          KitSegmented(selection: binding(\.video.fps), segments: CameraVideo.frameRates.map { fps in
            KitSegment("\(fps)", value: fps, isEnabled: fpsReason(fps, caps: caps) == nil)
          })
          .fixedSize()
        }
        FormRow("Codec", help: setup.video.codec == .hevc ? "HEVC: about 40% less data for the same picture" : "H.264 plays everywhere", systemImage: "film") {
          KitSegmented(selection: binding(\.video.codec), segments: [
            KitSegment("H.264", value: VideoCodec.h264),
            KitSegment("HEVC", value: VideoCodec.hevc, isEnabled: CameraEncoder.supports(.hevc)),
          ])
          .fixedSize()
        }
        FormRow("Bitrate", help: setup.video.bitrate == nil ? "Picked from the three above" : "The same whatever the picture", systemImage: "gauge.with.dots.needle.33percent") {
          KitPicker("Bitrate", selection: binding(\.video.bitrate), options: bitrates)
            .fixedSize()
        }
        FormRow("Microphone", help: "Not yet: live view and clips are silent", systemImage: "mic.slash") {
          Toggle("Microphone", isOn: .constant(false)).toggleStyle(.kitSwitch).labelsHidden().controlSize(.small).disabled(true)
        }
      }
    }
    .onAppear { place = setup.place }
    .onChange(of: setup.id) { place = setup.place }
    .task(id: [setup.video.height, setup.video.fps, together].map(String.init).joined(separator: ":") + setup.id) {
      costs = [:]
      guard together > 1, camera.isOn else { return }
      for height in CameraVideo.heights where caps.maxFPS(height: height) != nil {
        var trial = setup
        trial.video.height = height
        if let budget = await camera.estimate(trial) {
          costs["h\(height)"] = max(budget.hardwareCost ?? 0, budget.systemPressureCost ?? 0)
        }
      }
    }
  }

  private var bitrates: [(String, Int?)] {
    var options: [(String, Int?)] = [("Auto · \(CameraFormat.bitrate(setup.video.suggestedBitrate))", nil)]
    options += [500_000, 1_000_000, 2_000_000, 3_000_000, 4_000_000, 6_000_000, 8_000_000, 12_000_000, 16_000_000].map { (CameraFormat.bitrate($0), Optional($0)) }
    return options
  }

  private func sizeReason(_ height: Int, caps: CameraCapabilities, alone: CameraCapabilities) -> String? {
    if caps.maxFPS(height: height) == nil {
      return alone.maxFPS(height: height) != nil ? "only with 1 camera on" : "not on this camera"
    }
    if let cost = costs["h\(height)"], cost > 1 { return "over the budget with these cameras on" }
    return nil
  }

  private func fpsReason(_ fps: Int, caps: CameraCapabilities) -> String? {
    guard let most = caps.maxFPS(height: setup.video.height) else { return nil }
    return fps > most ? "up to \(most) fps" : nil
  }

  private func binding<Value>(_ path: WritableKeyPath<CameraSetup, Value>) -> Binding<Value> {
    Binding { setup[keyPath: path] } set: { value in
      var setup = setup
      setup[keyPath: path] = value
      camera.update(setup)
    }
  }

  private func rename() {
    let name = place.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != setup.place else { return }
    var setup = setup
    setup.place = name
    camera.update(setup)
  }
}

/// A lens's capabilities, kept: reading them walks all its formats
enum CameraCapabilitiesCache {
  @MainActor private static var cache: [String: CameraCapabilities] = [:]

  @MainActor static func get(_ device: String, together: Int) -> CameraCapabilities {
    let key = "\(device)#\(together)"
    if let caps = cache[key] { return caps }
    let caps = CameraRig.capabilities(of: device, together: together)
    cache[key] = caps
    return caps
  }
}

// MARK: - Expected usage

private struct UsageCard: View {
  let setup: CameraSetup
  @State private var camera = SecurityCamera.main
  @State private var scope = Scope.this

  enum Scope: Hashable {
    case this, all
  }

  var body: some View {
    let setups = scope == .this ? [setup] : camera.settings.cameras.filter(\.isOn)
    let live = setups.reduce(0.0) { $0 + Double($1.video.effectiveBitrate) / 8 }
    let clips = setups.reduce(0.0) { $0 + Double($1.video.effectiveBitrate) / 8 * camera.clipSecondsPerDay($1.id) }
    let storage = camera.settings.storage
    let days = Double(storage.days == 0 ? 30 : storage.days)
    let kept = camera.settings.cameras.filter(\.isOn).reduce(0.0) { $0 + Double($1.video.effectiveBitrate) / 8 * camera.clipSecondsPerDay($1.id) } * days
    let motion = setups.reduce(0.0) { $0 + camera.clipSecondsPerDay($1.id) }
    KitSection("Expected Usage", meta: [scope == .this ? setup.place : "All cameras", "estimate"], systemImage: "chart.bar", hue: .teal) {
      VStack(alignment: .leading, spacing: 8) {
        UsageTable(rows: rows(live: live, clips: clips, storage: storage))
        if storage.gigabytes > 0 {
          HStack(spacing: 10) {
            Text("All cameras, \(Int(days)) days of clips").kitFont(.caption)
            MeterBar(segments: [MeterSegment("Clips", value: min(kept, storage.gigabytes * 1e9), hue: kept > storage.gigabytes * 1e9 ? .red : .orange)], total: storage.gigabytes * 1e9, height: 6)
            Text("\(CameraFormat.bytes(kept)) of \(Int(storage.gigabytes)) GB").kitFont(.caption).monospacedDigit()
          }
          .padding(.horizontal, 12)
        }
        Text("\(setup.video.title) is about \(CameraFormat.bitrate(setup.video.effectiveBitrate)). Live view uses data only while someone watches. Clips assume \(CameraFormat.duration(motion)) of motion a day (the last 7 days).")
          .kitFont(.caption)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
      }
    } accessory: {
      KitSegmented(selection: $scope, options: [(setup.place, Scope.this), ("All Cameras", Scope.all)])
        .controlSize(.small)
    }
  }

  private func rows(live: Double, clips: Double, storage: CameraStoragePolicy) -> [UsageTable.Row] {
    var rows = [UsageTable.Row(name: "Live view", detail: "network · per viewer", second: CameraFormat.rate(live), day: CameraFormat.bytes(live * 86_400), month: CameraFormat.bytes(live * 86_400 * 30))]
    if storage.target == .hub {
      rows.append(UsageTable.Row(name: "Clips upload", detail: "network · to the hub", second: "–", day: CameraFormat.bytes(clips), month: CameraFormat.bytes(clips * 30)))
    }
    rows.append(UsageTable.Row(name: "Clips kept", detail: storage.target == .hub ? "the hub’s storage" : "storage · this \(KitDevice.nameInSentence)", second: "–", day: CameraFormat.bytes(clips), month: CameraFormat.bytes(clips * 30)))
    return rows
  }
}

// MARK: - Picture and power

private struct PictureCard: View {
  let setup: CameraSetup
  @State private var camera = SecurityCamera.main
  @State private var locking = false

  var body: some View {
    let caps = CameraCapabilitiesCache.get(setup.device, together: 1)
    KitSection("Picture and Power", meta: [setup.place, setup.profile?.title ?? "Custom"], systemImage: "bolt", hue: .green) {
      VStack(alignment: .leading, spacing: 0) {
        KitSegmented(selection: Binding { setup.profile } set: { profile in
          guard let profile else { return }
          var setup = setup
          profile.apply(to: &setup, stabilizes: caps.stabilization)
          camera.update(setup)
        }, segments: CameraProfile.allCases.map { KitSegment($0.title, value: Optional($0)) })
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        Text(setup.profile?.help ?? "Your own mix of the settings below.").kitFont(.caption).padding(.horizontal, 12).padding(.bottom, 6)
        budget
        FormCard {
          FormRow("Stabilization", help: caps.stabilization ? "Steadier picture, more processing" : "Not on this camera", systemImage: "hand.raised") {
            Toggle("Stabilization", isOn: binding(\.picture.stabilization))
              .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
              .disabled(!caps.stabilization)
          }
          FormRow("Focus", help: help(setup.picture.focus, locked: "nothing hunts when the light changes"), systemImage: "scope") {
            adjustment(\.picture.focus, slow: false).disabled(!caps.focus)
          }
          FormRow("Exposure", help: help(setup.picture.exposure, locked: "the picture keeps its brightness"), systemImage: "sun.max") {
            adjustment(\.picture.exposure, slow: true).disabled(!caps.exposure)
          }
          FormRow("White Balance", help: help(setup.picture.whiteBalance, locked: "colours stay as they are"), systemImage: "thermometer.sun") {
            adjustment(\.picture.whiteBalance, slow: true).disabled(!caps.whiteBalance)
          }
          FormRow("Locked Values", help: lockedLine, systemImage: "lock") {
            Button("Lock Now") {
              locking = true
              Task {
                await camera.lockNow(setup)
                locking = false
              }
            }
            .buttonStyle(.kit).controlSize(.small)
            .disabled(camera.units[setup.id] == nil || locking)
          }
        }
        .padding(.top, 6)
      }
    }
  }

  /// The system's own numbers: iOS's costs of the cameras together, or a Mac's pressure and Hub's CPU
  @ViewBuilder private var budget: some View {
    let budget = camera.budget
    HStack {
      Text("Budget").kitFont(.headline)
      Spacer()
      KitStatusPill(budget.pressure.title, systemImage: "thermometer.medium", hue: pressureHue(budget.pressure))
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    if budget.hardwareCost != nil || budget.systemPressureCost != nil {
      BudgetMeter(
        title: "Camera hardware", detail: camera.previousBudget?.hardwareCost.map { String(format: "was %.2f", $0) },
        value: budget.hardwareCost, previous: camera.previousBudget?.hardwareCost)
      BudgetMeter(
        title: "Heat and power", detail: camera.previousBudget?.systemPressureCost.map { String(format: "was %.2f", $0) },
        value: budget.systemPressureCost, previous: camera.previousBudget?.systemPressureCost)
      Text("iOS’s own numbers for the cameras together; the full bar is the limit. Past it iOS slows the cameras, then stops them.")
        .kitFont(.caption).padding(.horizontal, 12)
    } else {
      BudgetMeter(
        title: "Hub’s share of the CPU",
        detail: "Capture, motion and \(camera.orderedUnits.count == 1 ? "1 encoder" : "\(camera.orderedUnits.count) encoders")" + (camera.previousCPUShare.map { " · was \(Int(($0 * 100).rounded()))%" } ?? ""),
        value: camera.cpuShare, previous: camera.previousCPUShare,
        text: camera.cpuShare.map { "\(Int(($0 * 100).rounded()))%" })
      Text(budget.factors.isEmpty
        ? "\(SecurityCamera.deviceKind == "Mac" ? "macOS" : "The system") reports only its pressure for the camera, not what it costs."
        : "Pressure from \(budget.factors.joined(separator: ", ")).")
        .kitFont(.caption).padding(.horizontal, 12)
    }
  }

  private func pressureHue(_ pressure: CameraBudget.Pressure) -> Hue {
    switch pressure {
    case .nominal: .green
    case .fair: .yellow
    case .serious: .orange
    case .critical, .shutdown: .red
    }
  }

  private func adjustment(_ path: WritableKeyPath<CameraSetup, CameraPicture.Adjustment>, slow: Bool) -> some View {
    KitSegmented(selection: binding(path), segments: (slow ? CameraPicture.Adjustment.allCases : [.auto, .locked]).map {
      KitSegment(title($0), value: $0)
    })
    .fixedSize()
  }

  private func title(_ adjustment: CameraPicture.Adjustment) -> String {
    switch adjustment {
    case .auto: "Auto"
    case .slow: "Slow"
    case .locked: "Locked"
    }
  }

  private func help(_ adjustment: CameraPicture.Adjustment, locked: String) -> String {
    switch adjustment {
    case .auto: "Adjusts all the time"
    case .slow: "Adjusts every \(Int(CameraPicture.slowInterval)) s, not every frame"
    case .locked: "Locked: \(locked)"
    }
  }

  private var lockedLine: String {
    guard let locked = setup.locked else { return "Locks focus, exposure and colour where they are now" }
    var parts = [String]()
    if let iso = locked.iso { parts.append("ISO \(Int(iso.rounded()))") }
    if let shutter = locked.shutter, shutter > 0 { parts.append("1/\(Int((1 / shutter).rounded())) s") }
    if let temperature = locked.temperature { parts.append("\(Int(temperature.rounded())) K") }
    if let lens = locked.lensPosition { parts.append(String(format: "focus %.2f", lens)) }
    parts.append("taken \(CameraTime.short(locked.date))")
    return parts.joined(separator: " · ")
  }

  private func binding<Value>(_ path: WritableKeyPath<CameraSetup, Value>) -> Binding<Value> {
    Binding { setup[keyPath: path] } set: { value in
      var setup = setup
      setup[keyPath: path] = value
      camera.update(setup)
    }
  }
}

// MARK: - When to record

/// A Mac's camera: clips always, or only while nobody is using the Mac (locked, asleep, or no keyboard or mouse for a
/// while). Live view goes on while clips wait, unless it's turned off; Record for 1 Hour records anyway.
private struct WhenToRecordCard: View {
  let setup: CameraSetup
  @State private var camera = SecurityCamera.main

  var body: some View {
    let recording = setup.recording
    let unit = camera.units[setup.id]
    let until = camera.recordsUntil[setup.id]
    KitSection("When to Record", meta: [setup.place, statusLine], systemImage: "clock", hue: .purple) {
      FormCard(footer: "Hub checks only whether the \(KitDevice.nameInSentence) is in use; nothing about it leaves this \(KitDevice.nameInSentence). Viewers see that clips are paused.") {
        FormRow("Record Clips", systemImage: "record.circle") {
          KitSegmented(selection: binding(\.recording.when), segments: CameraRecording.When.allCases.map { KitSegment($0.title, value: $0) })
            .fixedSize()
        }
        if recording.when == .whenAway {
          FormRow("Away After", help: "No keyboard or mouse for this long. Locked or asleep counts at once.", systemImage: "hourglass") {
            KitPicker("Away After", selection: binding(\.recording.awayMinutes), options: CameraRecording.minuteChoices.map { ($0 == 1 ? "1 minute" : "\($0) minutes", $0) })
              .fixedSize()
          }
          FormRow("Live View While Paused", help: recording.liveWhilePaused ? "Viewers still see the picture; nothing is recorded" : "The camera stops while you use the \(KitDevice.nameInSentence)", systemImage: "eye") {
            Toggle("Live View While Paused", isOn: binding(\.recording.liveWhilePaused))
              .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
          }
          FormRow("Record for 1 Hour", help: until.map { "Recording until \($0.formatted(date: .omitted, time: .shortened)), even while you use it" } ?? "Records even while you use the \(KitDevice.nameInSentence)", systemImage: "record.circle.fill") {
            if until != nil {
              Button("Stop") { camera.recordForAnHour(setup.id, false) }.buttonStyle(.kit).controlSize(.small)
            } else {
              Button("Record for 1 Hour") { camera.recordForAnHour(setup.id) }.buttonStyle(.kit).controlSize(.small)
                .disabled(unit == nil)
            }
          }
        }
      }
    } accessory: {
      if unit?.clipsPaused == true {
        KitStatusPill("Paused", systemImage: "pause.fill", hue: .gray)
      } else if until != nil {
        KitStatusPill("Recording", systemImage: "record.circle", hue: .red)
      }
    }
  }

  /// What the Mac's use looks like now: "you typed 4 s ago", "locked"
  private var statusLine: String {
    guard setup.recording.when == .whenAway else { return "every motion" }
    guard let presence = camera.presence else { return "while you’re away" }
    if presence.isLocked { return "locked" }
    if presence.isAsleep { return "asleep" }
    guard let idle = presence.idle else { return "while you’re away" }
    return idle < 60 ? "you typed \(Int(idle)) s ago" : "no input for \(Int(idle / 60)) min"
  }

  private func binding<Value>(_ path: WritableKeyPath<CameraSetup, Value>) -> Binding<Value> {
    Binding { setup[keyPath: path] } set: { value in
      var setup = setup
      setup[keyPath: path] = value
      camera.update(setup)
    }
  }
}

// MARK: - Clips, access, Apple Home

private struct ClipsCard: View {
  @Environment(Hub.self) private var hub
  @State private var camera = SecurityCamera.main

  var body: some View {
    let storage = camera.settings.storage
    KitSection("Clips", meta: [storage.target == .hub ? "\(hub.settings.name)’s storage" : "this \(KitDevice.nameInSentence)", size], systemImage: "externaldrive", hue: .orange) {
      FormCard(footer: footer) {
        FormRow("Keep Clips On", systemImage: "externaldrive") {
          KitPicker("Keep Clips On", selection: $camera.settings.storage.target, options: [
            ("This \(KitDevice.name)", CameraStoragePolicy.Target.device),
            ("\(hub.settings.name)’s Storage", CameraStoragePolicy.Target.hub),
          ])
          .fixedSize()
          .disabled(!hub.hasStorage && storage.target == .device)
        }
        FormRow("Delete After", systemImage: "calendar") {
          KitPicker("Delete After", selection: $camera.settings.storage.days, options: [1, 3, 7, 14, 30, 90].map { ($0 == 1 ? "1 day" : "\($0) days", $0) } + [("Never", 0)])
            .fixedSize()
        }
        FormRow("Size Limit", help: "The oldest clips go first", systemImage: "internaldrive") {
          KitPicker("Size Limit", selection: $camera.settings.storage.gigabytes, options: [1.0, 2, 5, 10, 20, 50].map { ("\(Int($0)) GB", $0) } + [("None", 0.0)])
            .fixedSize()
        }
      }
    }
  }

  private var size: String {
    let bytes = camera.orderedUnits.flatMap(\.events).reduce(0) { $0 + $1.size }
    return CameraFormat.bytes(Double(bytes))
  }

  private var footer: String {
    let storage = camera.settings.storage
    let base = storage.target == .hub
      ? "Each clip goes to the hub’s storage when it ends; this \(KitDevice.nameInSentence) keeps a thumbnail."
      : "Clips stay on this \(KitDevice.nameInSentence)."
    return base + " A clip starts \(Int(storage.preRoll)) seconds before the motion and ends \(Int(storage.postRoll)) seconds after it."
  }
}

private struct AccessCard: View {
  let setup: CameraSetup
  @Environment(Hub.self) private var hub
  @State private var camera = SecurityCamera.main
  @State private var showsPassword = false
  @State private var editsPassword = false
  @State private var newPassword = ""

  var body: some View {
    let password = camera.password(setup.id)
    KitSection("Access", meta: [setup.place, "\(hub.settings.name)’s devices on Hub Network"], systemImage: "key", hue: .gray) {
      FormCard {
        FormRow("Password", help: "Other devices ask for it once to watch \(setup.place). This device’s own pages don’t.", systemImage: "key") {
          let text = Text(showsPassword ? password : "••••-••••-••••").monospaced().kitFont(.body)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
              text
              Button(showsPassword ? "Hide" : "Show") { showsPassword.toggle() }.buttonStyle(.kit).controlSize(.small)
              Button("Copy") { KitPasteboard.copy(password) }.buttonStyle(.kit).controlSize(.small)
              Button("Change…") { change() }.buttonStyle(.kit).controlSize(.small)
            }
            .fixedSize()
            Menu {
              Button(showsPassword ? "Hide" : "Show", systemImage: showsPassword ? "eye.slash" : "eye") { showsPassword.toggle() }
              Button("Copy", systemImage: "doc.on.doc") { KitPasteboard.copy(password) }
              Button("Change…", systemImage: "arrow.triangle.2.circlepath") { change() }
            } label: {
              text.lineLimit(1).fixedSize()
            }
            .menuStyle(.button).buttonStyle(.kit).controlSize(.small).fixedSize()
          }
        }
        if let unit = camera.units[setup.id] {
          FormRow("Shared", help: unit.isPublished ? "As “\(unit.shareName)” on Hub Network · \(unit.viewers == 1 ? "1 watching" : "\(unit.viewers) watching")" : unit.shareProblem ?? "Not shared yet", systemImage: "network", hue: unit.isPublished ? .green : .orange)
        }
      }
    }
    .kitSheet(isPresented: $editsPassword) {
      KitSheet(title: "Password for \(setup.place)", meta: "Devices that watch it sign in again with the new one.", systemImage: "key", hue: .indigo) {
        FormCard {
          FormRow("New Password", systemImage: "key") {
            TextField("Password", text: $newPassword).kitField(mono: true).autocorrectionDisabled().frame(maxWidth: 220)
          }
        }
      } footer: {
        Button("Cancel") { editsPassword = false }.keyboardShortcut(.cancelAction)
        Button("Change") {
          camera.setPassword(newPassword, for: setup.id)
          editsPassword = false
        }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(newPassword.count < 6)
      }
    }
  }

  private func change() {
    newPassword = SecurityCamera.makePassword()
    editsPassword = true
  }
}

private struct AppleHomeCard: View {
  var body: some View {
    KitSection("Apple Home", meta: "later", systemImage: "house", hue: .orange) {
      Text("Adding the cameras to the Home app as cameras with motion sensors comes later.")
        .kitFont(.caption).padding(8)
    } accessory: {
      Button("Add to Apple Home…") {}.buttonStyle(.kit).controlSize(.small).disabled(true)
    }
  }
}
#endif
