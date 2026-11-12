//
//  Cameras page.swift
//  Hub
//
//  A hub's cameras: every camera on the hub's network live in a grid, named by the place it watches with its device
//  under it, motion on the tile (an orange chip and box); the motion events of all of them in the inspector (Today or
//  the Week); Add Camera; where the clips are kept. A camera opens on its own page (`CameraPage`), this device's
//  cameras on their settings (`CameraSettingsPage`).
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
#if canImport(PlatformCamera)
import PlatformCamera
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
  @State private var pushed: CamerasRoute?
  @State private var span = EventSpan.today
  @State private var addsCamera = false
  @State private var camera = SecurityCamera.main
  @State private var alerts = CameraAlerts.main

  private var cameras: [HubCamera] {
    resources.compactMap(HubCamera.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    let cameras = cameras
    let viewers = CameraViewers.of(hub)
    Group {
      // Mac and iPad have no stack to push on: a camera's page opens in place, with a back button
      if idiom != .phone, let route = pushed {
        routed(route, viewers: viewers, back: { pushed = nil }).id(route)
      } else {
        grid(cameras, viewers: viewers)
          .navigationDestination(item: idiom == .phone ? $pushed : .constant(nil)) { route in
            routed(route, viewers: viewers, back: nil).hub(hub)
          }
      }
    }
    // A notification the user opened: its camera's page
    .task(id: [alerts.pendingOpen.map { "\($0.hub)|\($0.camera)" } ?? "", cameras.map(\.id).joined()]) {
      guard let open = alerts.pendingOpen, open.hub == hub.id.absoluteString,
            let camera = cameras.first(where: { $0.id == open.camera }) else { return }
      alerts.pendingOpen = nil
      pushed = .camera(camera)
    }
#if DEBUG
    .task(id: cameras.map(\.id)) {
      // --camera-open settings | camera | clip: a camera page at launch, for captures
      guard !Self.openedAtLaunch, let open = CommandLine.arguments.firstIndex(of: "--camera-open").map({ CommandLine.arguments[$0 + 1] }) else { return }
      if open == "settings" {
        Self.openedAtLaunch = true
        pushed = .settings
      } else if let first = cameras.first(where: { viewers.viewer($0).isOwn }) ?? cameras.first {
        Self.openedAtLaunch = true
        if open == "clip" {
          viewers.use(first)
          let viewer = viewers.viewer(first)
          for _ in 0..<40 where viewer.events.first(where: { $0.end != nil }) == nil { try? await Task.sleep(for: .milliseconds(500)) }
          viewers.release(first)
          if let event = viewer.events.first(where: { $0.end != nil }) { pushed = .clip(first, event.id) }
        } else {
          pushed = .camera(first)
        }
      }
    }
#endif
  }

  @ViewBuilder private func routed(_ route: CamerasRoute, viewers: CameraViewers, back: (() -> Void)?) -> some View {
    switch route {
    case .camera(let camera): CameraPage(camera: camera, viewers: viewers, back: back) { pushed = .settings }
    case .clip(let camera, let event): CameraPage(camera: camera, viewers: viewers, playing: event, back: back) { pushed = .settings }
    case .settings: CameraSettingsPage(back: back)
    }
  }

  private func grid(_ cameras: [HubCamera], viewers: CameraViewers) -> some View {
    PageWithInspector(name: "cameras", showsInspector: !cameras.isEmpty, floatsWhenNarrow: false) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          CameraBanners()
          if cameras.isEmpty {
            EmptyState(
              systemImage: "video", title: "No Cameras on \(hub.settings.name)",
              message: "Use this \(KitDevice.nameInSentence), or an old iPhone or iPad that stays at home: open Hub on it, go to \(hub.settings.name) › Cameras and turn its camera on."
            ) {
              if SecurityCamera.isSupported, !camera.isOn {
                Button("Use This \(KitDevice.name) as a Camera") { pushed = .settings }.buttonStyle(.kitPrimary)
              }
            }
            .padding(.top, 40)
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: idiom == .phone ? 280 : 360), spacing: KitMetrics.gutter * 1.5, alignment: .top)], spacing: KitMetrics.gutter * 1.5) {
              ForEach(cameras) { camera in
                CameraTile(camera: camera, viewers: viewers) { pushed = .camera(camera) }
              }
              if idiom != .phone, SecurityCamera.isSupported {
                AddCameraTile { pushed = .settings }
              }
            }
            if idiom == .phone {
              CameraEventsSection(cameras: cameras, viewers: viewers, span: $span) { camera, event in
                pushed = .clip(camera, event)
              }
            }
            CameraStorageLine(cameras: cameras, viewers: viewers)
          }
        }
        .padding(KitMetrics.gutter)
        .padding(.bottom, 24)
      }
    } inspector: {
      ScrollView {
        CameraEventsSection(cameras: cameras, viewers: viewers, span: $span) { camera, event in
          pushed = .clip(camera, event)
        }
        .padding(KitMetrics.gutter)
      }
    }
    .pageToolbar(String(localized: "Cameras"), meta: PageMeta.parts(hub, meta(cameras, viewers)), systemImage: HubPage.cameras.systemImage, hue: .indigo) {
      if SecurityCamera.isSupported {
        ToolGroup {
          Button(idiom == .phone ? "Camera" : "Add Camera", systemImage: idiom == .phone ? "web.camera" : "plus") {
            if idiom == .phone { pushed = .settings } else { addsCamera = true }
          }
          .kitPopover(isPresented: $addsCamera) {
            AddCameraPopover { addsCamera = false; pushed = .settings }
          }
        }
      }
    }
  }

#if DEBUG
  private static var openedAtLaunch = false
#endif

  private func meta(_ cameras: [HubCamera], _ viewers: CameraViewers) -> [String] {
    var parts = [String(localized: "\(cameras.count) cameras")]
    let moving = cameras.filter { viewers.viewer($0).motion?.isActive == true }.count
    if moving > 0 { parts.append(String(localized: "\(moving) with motion now")) }
    return parts
  }
#else
  var body: some View {
    EmptyState(systemImage: "video", title: "Cameras Aren’t Available Here", message: "Open Cameras on an iPhone, iPad or Mac.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .kitPane(.content)
  }
#endif
}

/// The sidebar row's mark: this device's cameras while they're on, orange while one sees motion
struct CamerasRowTrailing: View {
  var body: some View {
#if canImport(PlatformCamera)
    let camera = SecurityCamera.main
    if camera.phase == .on {
      Chip("On", systemImage: "record.circle", hue: camera.units.values.contains { $0.motion.isActive } ? .orange : .green).controlSize(.small)
    }
#endif
  }
}

#if canImport(PlatformCamera)
enum CamerasRoute: Hashable {
  case camera(HubCamera)
  /// A camera's page playing one of its clips
  case clip(HubCamera, String)
  /// This device as a camera
  case settings
}

enum EventSpan: String, Hashable {
  case today, week
}

extension View {
  /// A camera page's title bar: with a back button to the grid where the page opens in place (Mac, iPad)
  func cameraToolbar(
    _ title: String, meta: [String], systemImage: String, hue: Hue, back: (() -> Void)?,
    @ToolbarSlotBuilder tools: () -> [ToolbarSlot]
  ) -> some View {
    pageToolbar(title, title: {
      HStack(spacing: 10) {
        if let back {
          Button("Cameras", systemImage: "chevron.backward", action: back)
            .labelStyle(.iconOnly).buttonStyle(.kitRound).controlSize(.small)
            .keyboardShortcut("[", modifiers: .command)
        }
        KitTitle(title, meta: meta, systemImage: systemImage, hue: hue)
      }
    }, tools: tools)
  }
}

extension CameraViewers {
  private static var stores: [Hub.ID: CameraViewers] = [:]

  /// The hub's viewers, one store per hub for the app's life
  static func of(_ hub: Hub) -> CameraViewers {
    if let store = stores[hub.id] { return store }
    let store = CameraViewers(hub: hub)
    stores[hub.id] = store
    return store
  }
}

// MARK: - Banners

/// What keeps the cameras from working: Hub Network off, this device's cameras failing or their clips not stored
struct CameraBanners: View {
  @Environment(Hub.self) private var hub
  @State private var camera = SecurityCamera.main

  var body: some View {
    if !hub.net.isJoined {
      Banner(
        "Cameras need Hub Network",
        message: "This \(KitDevice.nameInSentence) reaches \(hub.settings.name)’s cameras through it, and it’s off here.",
        systemImage: "network", hue: .orange
      ) {
        Button("Open Network") { Navigator.main.open(hub, .network) }.buttonStyle(.kit)
      }
    }
    if camera.hubID == hub.id {
      if case .failed(let message) = camera.phase {
        Banner("This \(KitDevice.name)’s camera didn’t start", message: message, systemImage: "video.slash", hue: .red) {}
      } else if camera.isOn, let problem = camera.problem {
        Banner("A camera didn’t start", message: problem, systemImage: "video.slash", hue: .red) {}
      }
      if let storage = camera.orderedUnits.compactMap(\.storageProblem).first {
        Banner("Clips stay on this \(KitDevice.nameInSentence)", message: storage, systemImage: "externaldrive.badge.exclamationmark", hue: .red) {}
      }
    }
  }
}

// MARK: - Tiles

/// A camera in the grid: live, with its place and motion on the picture and its device in the foot; opens its page
private struct CameraTile: View {
  let camera: HubCamera
  let viewers: CameraViewers
  let open: () -> Void

  var body: some View {
    let viewer = viewers.viewer(camera)
    VStack(spacing: 0) {
      CameraLive(viewer: viewer, style: .tile)
        .aspectRatio(16 / 9, contentMode: .fit)
      HStack(spacing: 8) {
        Tile(systemImage: viewer.deviceSymbol, hue: .gray, size: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text(camera.name).kitFont(.headline).lineLimit(1)
          Text(viewer.tileLine).kitFont(.caption).lineLimit(1)
        }
        Spacer(minLength: 4)
        StatusDot(hue: viewer.hue, isHollow: viewer.state == .offline)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .kitSurface(.card)
    .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radiusCard))
    .contentShape(RoundedRectangle(cornerRadius: KitMetrics.radiusCard))
    .onTapGesture(perform: open)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .onAppear { viewers.use(camera) }
    .onDisappear { viewers.release(camera) }
  }
}

/// The grid's last tile: this device as a camera
private struct AddCameraTile: View {
  let open: () -> Void
  @State private var camera = SecurityCamera.main

  var body: some View {
    Button(action: open) {
      VStack(spacing: 8) {
        Image(systemName: camera.isOn ? "web.camera" : "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(.kitSecondary)
        Text(camera.isOn ? "This \(KitDevice.name) as a Camera" : "Add a Camera").kitFont(.headline)
        Text(camera.isOn
          ? String(localized: "\(camera.orderedUnits.count) cameras on · settings, zones and video")
          : String(localized: "Use this \(KitDevice.nameInSentence), or an old iPhone or iPad that stays at home."))
          .kitFont(.caption).multilineTextAlignment(.center).frame(maxWidth: 260)
      }
      .frame(maxWidth: .infinity, minHeight: 140)
      .padding(12)
      .background {
        RoundedRectangle(cornerRadius: KitMetrics.radiusCard)
          .strokeBorder(.kitBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
      }
      .contentShape(RoundedRectangle(cornerRadius: KitMetrics.radiusCard))
    }
    .buttonStyle(.plain)
  }
}

/// Add Camera: this device, or another one of the hub's
private struct AddCameraPopover: View {
  let openSettings: () -> Void
  @Environment(Hub.self) private var hub
  @State private var camera = SecurityCamera.main

  var body: some View {
    KitSection("Add a Camera", meta: String(localized: "Any Hub device with a camera"), systemImage: "plus", hue: .accent) {
      SidebarRow(String(localized: "This \(KitDevice.name)"), subtitle: thisDevice, systemImage: KitDevice.name == "Mac" ? "laptopcomputer" : "iphone") {
        Button(camera.isOn && camera.hubID == hub.id ? "Settings…" : "Set Up…") { openSettings() }
          .buttonStyle(.kitPrimary).controlSize(.small)
      }
      SidebarRow("An iPhone or iPad", subtitle: "Open Hub on it › \(hub.settings.name) › Cameras, and turn its camera on. It has to be on \(hub.settings.name) and Hub Network first.", systemImage: "ipad.and.iphone")
    }
    .frame(width: 440)
    .padding(8)
  }

  private var thisDevice: String {
    let names = camera.devices.map(\.name)
    let lenses = names.isEmpty ? String(localized: "No camera found") : names.joined(separator: ", ")
    return KitDevice.name == "Mac" ? String(localized: "\(lenses) · stays on while the Mac is awake") : String(localized: "\(lenses) · Hub stays open")
  }
}

// MARK: - The live picture

/// A camera's picture, with what's on it (place, live, motion and its box) or what keeps it away (its password, the
/// device offline, the camera paused)
struct CameraLive: View {
  enum Style {
    case tile, large
  }
  let viewer: CameraViewer
  var style = Style.tile
  @State private var password = ""

  var body: some View {
    let info = viewer.info
    let aspect = info.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16 / 9
    ZStack {
      CameraVideoView(renderer: viewer.renderer)
      if let box = viewer.motion?.box, viewer.motion?.isActive == true, viewer.state == .live {
        PictureSpace(aspect: aspect) { MotionBox(box: box) }
      }
      if viewer.state != .live || info?.paused != nil {
        Color.black.opacity(0.6)
        center.padding(12)
      }
      chips.padding(8)
    }
    .background(Color.black)
  }

  @ViewBuilder private var chips: some View {
    let isMotion = viewer.motion?.isActive == true && viewer.state == .live
    VStack {
      HStack(spacing: 6) {
        if style == .tile {
          VideoChip(title: viewer.camera.name)
        } else if viewer.state == .live {
          VideoChip(title: String(localized: "LIVE"), tone: .live)
          TimelineView(.periodic(from: .now, by: 1)) { context in
            VideoChip(title: context.date.formatted(date: .omitted, time: .standard))
          }
        }
        Spacer()
        // On a tile, paused clips win over motion: motion records nothing then
        if style == .tile, viewer.state == .live, viewer.info?.clipsPaused != nil {
          VideoChip(title: String(localized: "Clips paused"), systemImage: "pause.fill")
        } else if isMotion {
          VideoChip(title: style == .tile ? String(localized: "Motion") : String(localized: "Motion now"), systemImage: "figure.walk.motion", tone: .motion)
        } else if style == .tile, viewer.state == .live {
          VideoChip(title: String(localized: "LIVE"), tone: .live)
        }
      }
      Spacer()
      if style == .large, viewer.state == .live, let info = viewer.info {
        HStack {
          if let clipsPaused = info.clipsPaused {
            VideoChip(title: clipsPaused, systemImage: "pause.fill")
          }
          if let zone = info.zone, zone != CameraBox(x: 0, y: 0, width: 1, height: 1) {
            VideoChip(title: String(localized: "Zone"), systemImage: "rectangle.dashed")
          }
          Spacer()
          VideoChip(title: "\(info.width)×\(info.height) · \(info.fps) fps · \(VideoCodec(rawValue: info.codec ?? "h264")?.title ?? "H.264")", systemImage: "network")
        }
      }
    }
  }

  @ViewBuilder private var center: some View {
    VStack(spacing: 8) {
      switch viewer.state {
      case .needsPassword, .wrongPassword:
        Image(systemName: "key").font(.title2)
        Text(viewer.state == .wrongPassword ? "Wrong password for \(viewer.camera.name)" : "\(viewer.camera.name) asks for its password")
          .kitFont(.headline)
        if style == .large {
          Text("The hub can’t hand it over yet. Copy it from the camera’s settings on its device.").kitFont(.caption).foregroundStyle(.white.opacity(0.7))
        }
        HStack {
          SecureField("Password", text: $password).kitField(mono: true).frame(maxWidth: 180)
            .onSubmit { viewer.setPassword(password) }
          Button("Watch") { viewer.setPassword(password) }.buttonStyle(.kitPrimary).disabled(password.isEmpty)
        }
        .onTapGesture {}
      case .offline:
        Image(systemName: "video.slash").font(.title2)
        Text("\(viewer.camera.name) is offline").kitFont(.headline)
        if style == .large { Text("Its device isn’t on Hub Network now.").kitFont(.caption).foregroundStyle(.white.opacity(0.7)) }
      case .finding, .connecting:
        ProgressView().controlSize(.small).tint(.white)
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle").font(.title2)
        Text(message).kitFont(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
      case .live:
        if let paused = viewer.info?.paused {
          Image(systemName: "pause.circle").font(.title2)
          Text("\(viewer.camera.name) is paused").kitFont(.headline)
          Text(paused).kitFont(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
      }
    }
    .foregroundStyle(.white)
  }
}

extension CameraViewer {
  /// The camera's device under its name in the grid
  var tileLine: String {
    var parts = [info?.name ?? ""]
    switch state {
    case .live:
      if info?.paused != nil { parts.append(String(localized: "paused")) }
      else if info?.clipsPaused != nil { parts.append(String(localized: "clips paused")) }
      else if motion?.isActive == true { parts.append(String(localized: "motion now")) }
      else if let last = events.first { parts.append(String(localized: "last motion \(CameraTime.short(last.start))")) }
      else { parts.append(String(localized: "no motion yet")) }
    case .offline: parts.append(String(localized: "offline"))
    case .needsPassword, .wrongPassword: parts.append(String(localized: "needs its password"))
    case .finding, .connecting: parts.append(String(localized: "connecting…"))
    case .failed: parts.append(String(localized: "not reachable"))
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  var hue: Hue {
    switch state {
    case .live: info?.paused != nil ? .yellow : info?.clipsPaused != nil ? .gray : motion?.isActive == true ? .orange : .green
    case .offline: .gray
    case .failed, .wrongPassword: .red
    default: .gray
    }
  }

  /// The camera device's kind, from its info (iPhone · iOS 18)
  var deviceSymbol: String {
    let device = info?.device ?? ""
    if device.hasPrefix("iPhone") { return "iphone" }
    if device.hasPrefix("iPad") { return "ipad" }
    if device.hasPrefix("Mac") { return "laptopcomputer" }
    return "video"
  }
}

enum CameraTime {
  /// 21:05 today, Yesterday 21:05, Oct 30 21:05
  static func short(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return time }
    if Calendar.current.isDateInYesterday(date) { return String(localized: "yesterday \(time)") }
    return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
  }
}

// MARK: - Events across cameras

/// Today's (or the week's) motion events of all the cameras, newest first
private struct CameraEventsSection: View {
  let cameras: [HubCamera]
  let viewers: CameraViewers
  @Binding var span: EventSpan
  let open: (HubCamera, String) -> Void

  var body: some View {
    let events = events
    KitSection("Motion Events", meta: [span == .today ? String(localized: "Today") : String(localized: "Last 7 days"), String(localized: "\(events.count) events")], systemImage: "figure.walk.motion", hue: .orange) {
      if events.isEmpty {
        Text(span == .today ? "Nothing moved today. Clips of motion show up here." : "Nothing moved this week.")
          .kitFont(.caption).padding(8)
      }
      ForEach(events, id: \.event.id) { item in
        CameraEventRow(event: item.event, thumbnail: item.viewer.thumbnails[item.event.id], camera: item.camera.name) {
          open(item.camera, item.event.id)
        }
      }
    } accessory: {
      KitSegmented(selection: $span, options: [("Today", EventSpan.today), ("Week", EventSpan.week)])
        .controlSize(.small)
    }
  }

  private var events: [(camera: HubCamera, viewer: CameraViewer, event: CameraEvent)] {
    let since = span == .today ? Calendar.current.startOfDay(for: Date()) : Date().addingTimeInterval(-7 * 86_400)
    var events = [(camera: HubCamera, viewer: CameraViewer, event: CameraEvent)]()
    for camera in cameras {
      let viewer = viewers.viewer(camera)
      for event in viewer.events where event.start >= since {
        events.append((camera, viewer, event))
      }
    }
    return events.sorted { $0.event.start > $1.event.start }
  }
}

/// An event in a list: its thumbnail, the camera (or the time), its length and size, or Recording
struct CameraEventRow: View {
  let event: CameraEvent
  let thumbnail: Data?
  /// The camera's name, in a list across cameras
  var camera: String?
  var isSelected = false
  let open: () -> Void

  var body: some View {
    SidebarRow(camera ?? CameraTime.short(event.start), subtitle: subtitle) {
      CameraThumbnail(data: thumbnail, width: 64)
    } trailing: {
      if event.end == nil {
        Chip("Recording", systemImage: "record.circle", hue: .red).controlSize(.small)
      } else {
        Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(.kitSecondary)
      }
    }
    .isCurrent(isSelected)
    .action(open)
  }

  private var subtitle: String {
    var parts = [String]()
    if camera != nil { parts.append(CameraTime.short(event.start)) }
    if event.end != nil {
      parts.append(CameraFormat.duration(event.duration))
      if event.size > 0 { parts.append(CameraFormat.bytes(Double(event.size))) }
    } else {
      parts.append(String(localized: "now"))
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Storage

/// Where the cameras' clips are and how much of them there is
private struct CameraStorageLine: View {
  let cameras: [HubCamera]
  let viewers: CameraViewers
  @Environment(Hub.self) private var hub

  var body: some View {
    let viewers = cameras.map { self.viewers.viewer($0) }
    let events = viewers.flatMap(\.events)
    let onHub = viewers.filter { $0.info?.storage == CameraStoragePolicy.Target.hub.rawValue }.count
    let known = viewers.filter { $0.info != nil }.count
    HStack(spacing: 8) {
      Image(systemName: "externaldrive").foregroundStyle(Hue.orange.fill)
      Text(known == 0 ? "Clips" : onHub == known ? "Clips go to \(hub.settings.name)’s storage" : onHub == 0 ? "Clips stay on each camera" : "Clips on \(hub.settings.name)’s storage and on cameras")
        .kitFont(.callout)
      Spacer()
      Text(String(localized: "\(events.count) clips · \(CameraFormat.bytes(Double(events.reduce(0) { $0 + $1.size })))"))
        .kitFont(.caption).monospacedDigit()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .kitSurface(.card)
  }
}
#endif
#endif
