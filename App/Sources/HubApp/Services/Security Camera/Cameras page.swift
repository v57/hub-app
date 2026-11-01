//
//  Cameras page.swift
//  Hub
//
//  A hub's cameras: this device as one (on, off, password, motion sensitivity, where clips go and how long they stay),
//  and every camera on the hub's network with its live view; a camera opens with its motion events and clips.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
#if canImport(PlatformCamera)
import PlatformCamera
import PlatformMedia
#endif

struct CamerasPage: View {
  /// Whether this build has cameras (Apple's iPhone, iPad and Mac for now)
  static var isAvailable: Bool {
#if canImport(PlatformCamera)
    true
#else
    false
#endif
  }

  @Environment(Hub.self) private var hub
#if canImport(PlatformCamera)
  @HubState(\.networkResources) private var resources
  @Environment(\.kitIdiom) private var idiom
  @State private var opened: HubCamera?

  private var cameras: [HubCamera] {
    resources.compactMap(HubCamera.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    let cameras = cameras
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        if SecurityCamera.isSupported {
          ThisDeviceCamera()
        }
        if cameras.isEmpty {
          EmptyState(
            systemImage: "video", title: "No Cameras on \(hub.settings.name)",
            message: "Turn an old iPhone, iPad or Mac into a camera: open this page on it and turn on its camera. Your devices on Hub Network see it here."
          )
          .padding(.top, 40)
        } else {
          KitSection("Cameras", meta: [cameras.count == 1 ? "1 camera" : "\(cameras.count) cameras"], systemImage: "video", hue: .indigo) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 280 : 340), spacing: KitMetrics.gutter, alignment: .top)], spacing: KitMetrics.gutter) {
              ForEach(cameras) { camera in
                CameraTile(camera: camera) { opened = camera }
              }
            }
            .padding(4)
          }
          .kitSectionStyle(.plain)
        }
        if !hub.net.isJoined {
          Text("This \(KitDevice.nameInSentence) reaches cameras through Hub Network: turn it on on the Network page.")
            .kitFont(.caption)
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane(.content)
    .pageToolbar("Cameras", meta: PageMeta.parts(hub, [cameras.count == 1 ? "1 camera" : "\(cameras.count) cameras"]), systemImage: HubPage.cameras.systemImage, hue: .indigo) { }
    .navigationDestination(item: $opened) { camera in
      CameraDetail(camera: camera).hub(hub)
    }
  }
#else
  var body: some View {
    EmptyState(systemImage: "video", title: "Cameras Aren’t Available Here", message: "Open Cameras on an iPhone, iPad or Mac.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .kitPane(.content)
  }
#endif
}

/// The sidebar row's count: this device's camera while it's on
struct CamerasRowTrailing: View {
  var body: some View {
#if canImport(PlatformCamera)
    if SecurityCamera.main.phase == .on {
      Chip("On", systemImage: "record.circle", hue: SecurityCamera.main.motion.isActive ? .red : .green).controlSize(.small)
    }
#endif
  }
}

#if canImport(PlatformCamera)
// MARK: - This device

private struct ThisDeviceCamera: View {
  @Environment(Hub.self) private var hub
  @State private var camera = SecurityCamera.main
  @State private var showsPassword = false
  @State private var editsPassword = false
  @State private var newPassword = ""

  var body: some View {
    KitSection("This \(KitDevice.name)", meta: meta, systemImage: "web.camera", hue: .indigo) {
      SidebarRow("Use as a Security Camera", subtitle: subtitle, systemImage: "video", hue: camera.phase == .on ? .green : .gray) {
        Toggle("Use as a Security Camera", isOn: Binding { camera.isOn && camera.hubID == hub.id } set: { on in
          Task { on ? await camera.turnOn(hub: hub) : await camera.turnOff() }
        })
        .toggleStyle(.kitSwitch).labelsHidden().controlSize(.small)
        .disabled(camera.phase == .starting)
      }
      if case .failed(let message) = camera.phase {
        Text(message).kitFont(.caption).foregroundStyle(Hue.red.text).padding(6)
      }
      if camera.isOn, camera.hubID == hub.id {
        ForEach([camera.shareProblem, camera.interruption, camera.storageProblem].compactMap { $0 }, id: \.self) { problem in
          Label(problem, systemImage: "exclamationmark.triangle").kitFont(.caption).foregroundStyle(Hue.orange.text).padding(6)
        }
      }
      if camera.isOn, camera.hubID != hub.id, let other = camera.hub {
        Text("The camera is on for \(other.settings.name). Turning it on here moves it.").kitFont(.caption).padding(6)
      }
      FormCard {
        FormRow("Password", help: "Your devices ask for it once to watch.", systemImage: "key") {
          let password = Text(showsPassword ? camera.password : "••••-••••-••••").monospaced().kitFont(.body)
          // Buttons where they fit, a menu on a phone
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
              password
              Button(showsPassword ? "Hide" : "Show") { showsPassword.toggle() }.buttonStyle(.kit).controlSize(.small)
              Button("Copy") { KitPasteboard.copy(camera.password) }.buttonStyle(.kit).controlSize(.small)
              Button("Change…") { changePassword() }.buttonStyle(.kit).controlSize(.small)
            }
            .fixedSize()
            Menu {
              Button(showsPassword ? "Hide" : "Show", systemImage: showsPassword ? "eye.slash" : "eye") { showsPassword.toggle() }
              Button("Copy", systemImage: "doc.on.doc") { KitPasteboard.copy(camera.password) }
              Button("Change…", systemImage: "arrow.triangle.2.circlepath") { changePassword() }
            } label: {
              password.lineLimit(1).fixedSize()
            }
            .menuStyle(.button).buttonStyle(.kit).controlSize(.small).fixedSize()
          }
        }
        let devices = camera.devices
        if devices.count > 1 {
          FormRow("Camera", systemImage: "camera") {
            Picker("Camera", selection: $camera.settings.device) {
              Text("Default").tag(String?.none)
              ForEach(devices) { device in Text(device.name).tag(Optional(device.id)) }
            }
            .labelsHidden().fixedSize()
          }
        }
        FormRow("Quality", systemImage: "sparkles.tv") {
          Picker("Quality", selection: $camera.settings.quality) {
            ForEach(SecurityCamera.Quality.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .labelsHidden().fixedSize()
        }
        FormRow("Motion Sensitivity", help: "Higher catches smaller movement, and more false alarms.", systemImage: "figure.walk.motion") {
          KitSlider("Motion Sensitivity", value: $camera.settings.sensitivity, in: 0...1, step: 0.1) { "\(Int(($0 * 100).rounded()))%" }
            .frame(maxWidth: 220)
        }
      }
      FormCard(footer: storageFooter) {
        FormRow("Keep Clips On", systemImage: "externaldrive") {
          Picker("Keep Clips On", selection: $camera.settings.storage.target) {
            Text("This \(KitDevice.name)").tag(CameraStoragePolicy.Target.device)
            Text("\(hub.settings.name)’s Storage").tag(CameraStoragePolicy.Target.hub)
          }
          .labelsHidden().fixedSize()
          .disabled(!hub.hasStorage && camera.settings.storage.target == .device)
        }
        FormRow("Delete After", systemImage: "calendar") {
          Picker("Delete After", selection: $camera.settings.storage.days) {
            ForEach([1, 3, 7, 14, 30, 90], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
            Text("Never").tag(0)
          }
          .labelsHidden().fixedSize()
        }
        FormRow("Size Limit", systemImage: "internaldrive") {
          Picker("Size Limit", selection: $camera.settings.storage.gigabytes) {
            ForEach([1.0, 2, 5, 10, 20, 50], id: \.self) { Text("\(Int($0)) GB").tag($0) }
            Text("None").tag(0.0)
          }
          .labelsHidden().fixedSize()
        }
      }
    }
    .kitSheet(isPresented: $editsPassword) {
      KitSheet(title: "Camera Password", meta: "Devices that watch this camera sign in again with the new one.", systemImage: "key", hue: .indigo) {
        FormCard {
          FormRow("New Password", systemImage: "key") {
            TextField("Password", text: $newPassword).kitField(mono: true).autocorrectionDisabled().frame(maxWidth: 220)
          }
        }
      } footer: {
        Button("Cancel") { editsPassword = false }.keyboardShortcut(.cancelAction)
        Button("Change") {
          camera.password = newPassword
          editsPassword = false
        }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(newPassword.count < 6)
      }
    }
  }

  private func changePassword() {
    newPassword = SecurityCamera.makePassword()
    editsPassword = true
  }

  private var meta: [String] {
    guard camera.isOn, camera.hubID == hub.id else { return ["Off"] }
    return [camera.motion.isActive ? "Recording" : "Watching", "\(camera.events.count) events"]
  }

  private var subtitle: String {
    switch camera.phase {
    case .off, .failed: return "Watches for motion and records clips. Only devices on \(hub.settings.name)’s network with the password can watch."
    case .starting: return "Starting…"
    case .on:
      var parts = [camera.device?.name ?? "Camera"]
      parts.append(camera.isPublished ? "Shared on Hub Network" : "Not shared yet")
      if KitDevice.name != "Mac" { parts.append("Keep Hub open") }
      return parts.joined(separator: " · ")
    }
  }

  private var storageFooter: String {
    let base = camera.settings.storage.target == .hub
      ? "Each clip goes to the hub’s storage when it ends; this \(KitDevice.nameInSentence) keeps a thumbnail."
      : "Clips stay on this \(KitDevice.nameInSentence)."
    return base + " A clip starts a few seconds before the motion and ends \(Int(camera.settings.storage.postRoll)) seconds after it."
  }
}

// MARK: - A camera of the hub

/// A camera's live view in the grid, which opens its events
private struct CameraTile: View {
  let camera: HubCamera
  let open: () -> Void
  @Environment(Hub.self) private var hub
  @State private var viewer: CameraViewer?
  @State private var providers = [HubNetworkProvider]()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let viewer {
        CameraLive(viewer: viewer)
          .aspectRatio(16 / 9, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radiusCard - 4))
      }
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(camera.name).kitFont(.headline)
          if let viewer { Text(viewer.statusLine).kitFont(.caption) }
        }
        Spacer()
        if let viewer, viewer.motion?.isActive == true {
          Chip("Motion", systemImage: "figure.walk.motion", hue: .red).controlSize(.small)
        }
        Button("Events", systemImage: "list.bullet.rectangle") { open() }.buttonStyle(.kit).controlSize(.small)
      }
    }
    .padding(KitMetrics.cardPadding)
    .kitSurface(.card)
    .hubStream("network/providers/list", CameraProviderRequest(resourceId: camera.id), initial: [], to: $providers)
    .onAppear { if viewer == nil { viewer = CameraViewer(camera: camera, hub: hub) } }
    .onChange(of: providers, initial: true) { _, providers in viewer?.providers(providers) }
    .onDisappear { viewer?.stop() }
  }
}

struct CameraProviderRequest: Encodable, Hashable, Sendable {
  let resourceId: String
}

/// The live picture, or what keeps it away
private struct CameraLive: View {
  let viewer: CameraViewer
  @State private var password = ""

  // The video is a platform layer that SwiftUI can't draw over, so it's on screen only while live
  var body: some View {
    if viewer.state == .live {
      CameraVideoView(renderer: viewer.renderer)
    } else {
      ZStack {
        Color.black
        switch viewer.state {
        case .needsPassword, .wrongPassword:
          VStack(spacing: 8) {
            Text(viewer.state == .wrongPassword ? "Wrong password" : "This camera needs its password")
              .kitFont(.headline).foregroundStyle(.white)
            HStack {
              SecureField("Password", text: $password).kitField(mono: true).frame(maxWidth: 200)
                .onSubmit { viewer.setPassword(password) }
              Button("Watch") { viewer.setPassword(password) }.buttonStyle(.kitPrimary).disabled(password.isEmpty)
            }
          }
          .padding()
        default:
          // What it is is in the status line beside the picture
          Image(systemName: viewer.state == .offline ? "video.slash" : "video").font(.title).foregroundStyle(.white.opacity(0.6))
        }
      }
    }
  }
}

extension CameraViewer {
  var statusLine: String {
    switch state {
    case .finding: "Looking for the camera…"
    case .offline: "Offline: its device isn’t on Hub Network"
    case .needsPassword: "Needs its password"
    case .wrongPassword: "Wrong password"
    case .connecting: "Connecting…"
    case .live:
      if motion?.isActive == true { "Live · Motion" }
      else if let info { "Live · \(info.width)×\(info.height) · \(info.fps) fps" } else { "Live" }
    case .failed(let message): message
    }
  }
}

// MARK: - A camera's events

private struct CameraDetail: View {
  let camera: HubCamera
  @Environment(Hub.self) private var hub
  @State private var viewer: CameraViewer?
  @State private var providers = [HubNetworkProvider]()
  @State private var playing: CameraEvent?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: KitMetrics.gutter) {
        if let viewer {
          CameraLive(viewer: viewer)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radiusCard))
            .frame(maxWidth: 960)
          KitSection("Motion Events", meta: eventsMeta(viewer), systemImage: "figure.walk.motion", hue: .red) {
            if viewer.events.isEmpty {
              Text(viewer.state == .live ? "Nothing moved yet. Clips of motion show up here." : viewer.statusLine)
                .kitFont(.caption).padding(6)
            }
            ForEach(viewer.events) { event in
              CameraEventRow(event: event, thumbnail: viewer.thumbnails[event.id]) { playing = event }
            }
          }
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane(.content)
    .pageToolbar(camera.name, meta: [viewer?.statusLine ?? ""], systemImage: "video", hue: .indigo) { }
    .hubStream("network/providers/list", CameraProviderRequest(resourceId: camera.id), initial: [], to: $providers)
    .onAppear { if viewer == nil { viewer = CameraViewer(camera: camera, hub: hub) } }
    .onChange(of: providers, initial: true) { _, providers in viewer?.providers(providers) }
    .onDisappear { viewer?.stop() }
    .kitSheet(item: $playing) { event in
      if let viewer { ClipPlayer(viewer: viewer, event: event) }
    }
  }

  private func eventsMeta(_ viewer: CameraViewer) -> [String] {
    let today = viewer.events.filter { Calendar.current.isDateInToday($0.start) }.count
    return ["\(viewer.events.count) kept", "\(today) today"]
  }
}

private struct CameraEventRow: View {
  let event: CameraEvent
  let thumbnail: Data?
  let play: () -> Void

  var body: some View {
    SidebarRow(event.start.formatted(date: .abbreviated, time: .standard), subtitle: subtitle, icon: {
      Group {
        if let thumbnail, let image = Image(data: thumbnail) {
          image.resizable().aspectRatio(16 / 9, contentMode: .fill)
        } else {
          Color.black.opacity(0.6)
        }
      }
      .frame(width: 64, height: 36)
      .clipShape(RoundedRectangle(cornerRadius: 4))
    }) {
      if event.end == nil {
        Chip("Recording", systemImage: "record.circle", hue: .red).controlSize(.small)
      } else {
        Button("Play", systemImage: "play.fill") { play() }.buttonStyle(.kit).controlSize(.small).disabled(event.clip == nil)
      }
    }
  }

  private var subtitle: String {
    var parts = [Duration.seconds(event.duration.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))]
    parts.append("\(Int((event.peak * 100).rounded()))% moved")
    if event.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(event.size), countStyle: .file)) }
    parts.append(event.storage == "hub" ? "On the hub" : "On the camera")
    return parts.joined(separator: " · ")
  }
}

/// Downloads a clip, then plays it
private struct ClipPlayer: View {
  let viewer: CameraViewer
  let event: CameraEvent
  @Environment(\.kitDismiss) private var dismiss
  @State private var player = PlatformPlayer()
  @State private var file: URL?
  @State private var error: String?

  var body: some View {
    KitSheet(title: event.start.formatted(date: .abbreviated, time: .standard), meta: viewer.camera.name, systemImage: "play.rectangle", hue: .indigo, status: file == nil && error == nil ? .working : .idle) {
      ZStack {
        PlatformVideoView(player: player)
        if let error {
          Text(error).kitFont(.caption).foregroundStyle(.white).padding()
        } else if file == nil {
          Text("Downloading the clip…").kitFont(.caption).foregroundStyle(.white.opacity(0.8))
        }
      }
      .aspectRatio(16 / 9, contentMode: .fit)
      .frame(minWidth: 320, idealWidth: 720)
      .clipShape(RoundedRectangle(cornerRadius: 8))
    } footer: {
      if let file {
        ShareLink(item: file).buttonStyle(.kit)
      }
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }
    .task {
      do {
        let file = try await viewer.downloadClip(event)
        self.file = file
        try await player.open(file)
        player.play()
      } catch {
        self.error = error.localizedDescription
      }
    }
    .onDisappear {
      player.stop()
      if let file { try? FileManager.default.removeItem(at: file) }
    }
  }
}
#endif
#endif
