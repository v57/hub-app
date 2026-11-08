//
//  Camera page.swift
//  Hub
//
//  One camera: the live picture large, the day's timeline under it with each motion event as a mark and Live at its
//  end; the day's events and the camera's details in the inspector. A clip plays in place of the live picture, with
//  Previous and Next event, Save, Share and Delete, and its details.
//

#if canImport(ComponentKit) && canImport(PlatformCamera)
import SwiftUI
import ComponentKit
import PlatformCamera
import PlatformMedia

struct CameraPage: View {
  let camera: HubCamera
  let viewers: CameraViewers
  /// Back to the grid, where the page opens in place
  let back: (() -> Void)?
  let openSettings: () -> Void
  @Environment(Hub.self) private var hub
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.showToast) private var showToast
  /// The event whose clip plays; nil for live
  @State private var playing: String?
  @State private var clip = ClipPlayback()
  @State private var day = Calendar.current.startOfDay(for: Date())
  @State private var saving: URL?
  @State private var savesClip = false
  @State private var deletes = false
  @State private var alerts = CameraAlerts.main

  init(camera: HubCamera, viewers: CameraViewers, playing: String? = nil, back: (() -> Void)?, openSettings: @escaping () -> Void) {
    self.camera = camera
    self.viewers = viewers
    self.back = back
    self.openSettings = openSettings
    _playing = State(initialValue: playing)
  }

  var body: some View {
    let viewer = viewers.viewer(camera)
    let event = playing.flatMap { id in viewer.events.first { $0.id == id } }
    PageWithInspector(name: "camera", showsInspector: true) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Group {
            if let event {
              ClipView(clip: clip, event: event)
            } else {
              CameraLive(viewer: viewer, style: .large)
            }
          }
          .aspectRatio(16 / 9, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: idiom == .phone ? 0 : KitMetrics.radiusXL))
          .padding(.horizontal, idiom == .phone ? -KitMetrics.gutter : 0)
          dayHeader(viewer)
          EventTimeline(
            day: DateInterval(start: day, duration: 86_400), marks: marks(viewer), selected: playing,
            playhead: event.map { $0.start.addingTimeInterval(clip.position) }, isLive: playing == nil,
            select: { playing = $0 }, live: { playing = nil })
          if idiom == .phone {
            inspector(viewer, event: event)
          }
        }
        .padding(KitMetrics.gutter)
        .padding(.bottom, 24)
      }
    } inspector: {
      ScrollView {
        inspector(viewer, event: event).padding(KitMetrics.gutter)
      }
    }
    .cameraToolbar(camera.name, meta: meta(viewer, event: event), systemImage: event == nil ? "video" : "figure.walk.motion", hue: event == nil ? .indigo : .orange, back: back) {
      if let event {
        ToolGroup(iconOnly: true) {
          Button("Previous Event", systemImage: "chevron.backward") { step(viewer, from: event, by: 1) }
            .disabled(neighbour(viewer, of: event, by: 1) == nil)
          Button("Next Event", systemImage: "chevron.forward") { step(viewer, from: event, by: -1) }
            .disabled(neighbour(viewer, of: event, by: -1) == nil)
        }
        ToolGroup {
          Button("Save…", systemImage: "square.and.arrow.down") { save() }.disabled(clip.file == nil)
          if let file = clip.file {
            ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
          }
          Button("Delete Clip", systemImage: "trash") { deletes = true }
        }
        ToolGroup {
          Button("Live", systemImage: "dot.radiowaves.left.and.right") { playing = nil }
        }
      } else if viewer.isOwn {
        ToolGroup {
          Button("Settings", systemImage: "gearshape") { openSettings() }
        }
      } else {
        ToolGroup {
          let follows = alerts.isFollowing(camera, on: hub)
          Button(follows ? "Motion Alerts On" : "Motion Alerts", systemImage: follows ? "bell.fill" : "bell") {
            Task { await setAlerts(!follows) }
          }
          .help(follows ? "This device shows a notification when \(camera.name) sees motion. Click to stop." : "Show a notification on this device when \(camera.name) sees motion")
        }
      }
    }
    .fileMover(isPresented: $savesClip, file: saving) { _ in saving = nil }
    .kitConfirmation(
      "Delete this clip?", isPresented: $deletes,
      message: "It’s deleted from \(camera.name) and wherever its clips are kept, for everyone who watches it.",
      systemImage: "trash", confirm: "Delete"
    ) {
      guard let event else { return }
      Task { await delete(event, viewer: viewer) }
    }
    .task(id: event?.id) {
      if let event {
        day = Calendar.current.startOfDay(for: event.start)
        clip.load(event, from: viewer)
      } else {
        clip.close()
      }
    }
    .onAppear { viewers.use(camera) }
    .onDisappear {
      viewers.release(camera)
      clip.close()
    }
  }

  /// Motion alerts straight from the camera over Hub Network, no push service; notifications are asked for here
  private func setAlerts(_ on: Bool) async {
    await alerts.setFollowing(on, camera, on: hub)
    if let problem = alerts.problem {
      showToast(problem, systemImage: "bell.slash")
    } else {
      showToast(on ? "Motion alerts on for \(camera.name)" : "Motion alerts off", systemImage: on ? "bell.fill" : "bell.slash")
    }
  }

  // MARK: Parts

  private func dayHeader(_ viewer: CameraViewer) -> some View {
    let events = viewer.events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
    let recorded = events.reduce(0) { $0 + $1.duration }
    let title = HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(dayTitle(day)).kitFont(.headline)
      Text(events.count == 1
        ? String(localized: "1 event · \(CameraFormat.duration(recorded)) recorded")
        : String(localized: "\(events.count) events · \(CameraFormat.duration(recorded)) recorded"))
        .kitFont(.caption)
        .lineLimit(1)
    }
    let segmented = KitSegmented(selection: $day, segments: days(viewer).map { KitSegment(dayTitle($0), value: $0) })
      .controlSize(.small)
    // The phone has no room for both on one line: the days go under the title
    return Group {
      if idiom == .phone {
        VStack(alignment: .leading, spacing: 8) {
          title
          segmented
        }
      } else {
        HStack(spacing: 10) {
          title
          Spacer()
          segmented
        }
      }
    }
  }

  @ViewBuilder private func inspector(_ viewer: CameraViewer, event: CameraEvent?) -> some View {
    VStack(spacing: KitMetrics.gutter) {
      if let event {
        KitSection("Clip", meta: [CameraFormat.duration(event.duration), CameraFormat.bytes(Double(event.size))], systemImage: "record.circle", hue: .red) {
          CameraDetailRows(rows: [
            (String(localized: "Camera"), [camera.name, viewer.info?.name].compactMap { $0 }.joined(separator: " · ")),
            (String(localized: "Motion"), "\(event.start.formatted(date: .omitted, time: .standard)) – \((event.end ?? Date()).formatted(date: .omitted, time: .standard))"),
            (String(localized: "Includes"), String(localized: "a few seconds before and after")),
            (String(localized: "Size"), [CameraFormat.bytes(Double(event.size)), viewer.info.map { "\($0.width)×\($0.height)" }].compactMap { $0 }.joined(separator: " · ")),
            (String(localized: "Stored on"), event.storage == CameraStoragePolicy.Target.hub.rawValue ? String(localized: "\(hub.settings.name)’s storage") : String(localized: "the camera’s device")),
          ])
          if let error = clip.error {
            Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).padding(8)
          }
        }
      }
      let events = viewer.events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
      KitSection("Motion Events", meta: [dayTitle(day), events.count == 1 ? String(localized: "1 event") : String(localized: "\(events.count) events")], systemImage: "figure.walk.motion", hue: .orange) {
        if events.isEmpty {
          Text(viewer.state == .live ? String(localized: "Nothing moved. Clips of motion show up here.") : viewer.tileLine)
            .kitFont(.caption).padding(8)
        }
        ForEach(events) { item in
          CameraEventRow(event: item, thumbnail: viewer.thumbnails[item.id], isSelected: item.id == playing) {
            if item.end != nil { playing = item.id }
          }
        }
      }
      if event == nil, let info = viewer.info {
        KitSection("Camera", meta: info.name, systemImage: viewer.deviceSymbol, hue: .gray) {
          CameraDetailRows(rows: details(info, viewer: viewer))
        } accessory: {
          if viewer.isOwn {
            Button("Settings…") { openSettings() }.buttonStyle(.kit).controlSize(.small)
          }
        }
      }
    }
  }

  private func details(_ info: CameraInfo, viewer: CameraViewer) -> [(String, String)] {
    var rows = [(String, String)]()
    if let device = info.device { rows.append((String(localized: "Device"), device)) }
    rows.append((String(localized: "Lens"), info.camera))
    if let power = info.power { rows.append((String(localized: "Power"), power)) }
    let codec = VideoCodec(rawValue: info.codec ?? "h264")?.title ?? "H.264"
    rows.append((String(localized: "Stream"), ["\(info.width)×\(info.height) · \(info.fps) fps", codec, info.bitrate.map(CameraFormat.bitrate)].compactMap { $0 }.joined(separator: " · ")))
    rows.append((String(localized: "Network"), viewer.behind > 0.5 ? String(localized: "Hub Network · \(String(format: "%.1f", viewer.behind)) s behind") : "Hub Network"))
    rows.append((String(localized: "Clips"), info.storage == CameraStoragePolicy.Target.hub.rawValue ? String(localized: "\(hub.settings.name)’s storage") : String(localized: "on the camera’s device")))
    rows.append((String(localized: "Sensitivity"), "\(Int((info.sensitivity * 100).rounded()))%"))
    if let viewers = info.viewers { rows.append((String(localized: "Watching"), viewers == 1 ? String(localized: "1 device") : String(localized: "\(viewers) devices"))) }
    return rows
  }

  private func meta(_ viewer: CameraViewer, event: CameraEvent?) -> [String] {
    if let event {
      let events = viewer.events.filter { Calendar.current.isDate($0.start, inSameDayAs: event.start) }.reversed()
      let index = (events.firstIndex { $0.id == event.id }.map { events.distance(from: events.startIndex, to: $0) + 1 }) ?? 0
      return [String(localized: "Motion at \(event.start.formatted(date: .omitted, time: .shortened))"), CameraFormat.duration(event.duration), String(localized: "event \(index) of \(events.count)")]
    }
    var parts = [viewer.info?.name ?? viewer.tileLine]
    if let info = viewer.info { parts.append(String(localized: "\(info.width)×\(info.height) · \(info.fps) fps")) }
    if let watching = viewer.info?.viewers, watching > 0 { parts.append(String(localized: "\(watching) watching")) }
    return parts
  }

  private func marks(_ viewer: CameraViewer) -> [EventTimeline.Mark] {
    viewer.events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.map {
      EventTimeline.Mark(id: $0.id, start: $0.start, end: $0.end ?? Date())
    }
  }

  /// Today, yesterday and the other days of the week with events
  private func days(_ viewer: CameraViewer) -> [Date] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    var days = [today, calendar.date(byAdding: .day, value: -1, to: today) ?? today]
    for event in viewer.events {
      let day = calendar.startOfDay(for: event.start)
      if !days.contains(day), days.count < 5 { days.append(day) }
    }
    if !days.contains(day) { days.append(day) }
    return days.sorted(by: >)
  }

  private func dayTitle(_ day: Date) -> String {
    if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
    if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
    return day.formatted(.dateTime.month(.abbreviated).day())
  }

  // MARK: Actions

  /// The finished event `by` places older (1) or newer (-1)
  private func neighbour(_ viewer: CameraViewer, of event: CameraEvent, by step: Int) -> CameraEvent? {
    let events = viewer.events.filter { $0.end != nil }
    guard let index = events.firstIndex(where: { $0.id == event.id }) else { return nil }
    let next = index + step
    return events.indices.contains(next) ? events[next] : nil
  }

  private func step(_ viewer: CameraViewer, from event: CameraEvent, by step: Int) {
    if let next = neighbour(viewer, of: event, by: step) { playing = next.id }
  }

  /// A copy of the clip moved where the user picks
  private func save() {
    guard let file = clip.file else { return }
    let copy = URL.temporaryDirectory.appending(path: "Save", directoryHint: .isDirectory).appending(path: file.lastPathComponent)
    try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: copy)
    do {
      try FileManager.default.copyItem(at: file, to: copy)
      saving = copy
      savesClip = true
    } catch {
      showToast(error.localizedDescription, systemImage: "exclamationmark.triangle")
    }
  }

  private func delete(_ event: CameraEvent, viewer: CameraViewer) async {
    let next = neighbour(viewer, of: event, by: 1) ?? neighbour(viewer, of: event, by: -1)
    do {
      try await viewer.delete(event)
      playing = next?.id
      showToast("Clip deleted", systemImage: "trash")
    } catch {
      showToast("The clip wasn’t deleted: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
    }
  }
}

/// Label and value rows in a section
struct CameraDetailRows: View {
  let rows: [(String, String)]

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          Text(row.0).kitFont(.caption)
          Text(row.1).kitFont(.body).textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }
}

// MARK: - A clip

/// Downloads an event's clip and plays it, for the camera's page
@MainActor @Observable
final class ClipPlayback {
  let player = PlatformPlayer()
  private(set) var event: CameraEvent?
  private(set) var file: URL?
  private(set) var error: String?
  private(set) var position: Double = 0
  private(set) var duration: Double = 0
  private(set) var isPlaying = false
  private var loading: Task<Void, Never>?

  init() {
    player.timeInterval = 0.1
    player.onEvent = { [weak self] _ in self?.sync() }
  }

  func load(_ event: CameraEvent, from viewer: CameraViewer) {
    guard event.id != self.event?.id else { return }
    close()
    self.event = event
    loading = Task {
      do {
        let file = try await viewer.downloadClip(event)
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: file)
          return
        }
        self.file = file
        try await player.open(file)
        player.play()
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }

  func close() {
    loading?.cancel()
    loading = nil
    player.stop()
    if let file { try? FileManager.default.removeItem(at: file) }
    file = nil
    event = nil
    error = nil
    position = 0
    duration = 0
    isPlaying = false
  }

  func toggle() {
    if player.isPlaying {
      player.pause()
    } else {
      if duration > 0, position >= duration - 0.1 { player.seek(to: 0) }
      player.play()
    }
  }

  func seek(_ seconds: Double) {
    player.seek(to: seconds)
    position = seconds
  }

  private func sync() {
    position = player.position
    duration = player.duration
    isPlaying = player.isPlaying
  }
}

/// A clip playing in place of the live picture, with its transport under it
private struct ClipView: View {
  let clip: ClipPlayback
  let event: CameraEvent

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black
      PlatformVideoView(player: clip.player)
      if clip.file == nil {
        VStack(spacing: 8) {
          if let error = clip.error {
            Image(systemName: "exclamationmark.triangle").font(.title2)
            Text(error).kitFont(.caption).multilineTextAlignment(.center)
          } else {
            ProgressView().controlSize(.small).tint(.white)
            Text("Getting the clip…").kitFont(.caption)
          }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      VStack {
        HStack {
          VideoChip(title: String(localized: "Recorded · \(event.start.formatted(date: .omitted, time: .standard))"), systemImage: "record.circle")
          Spacer()
        }
        Spacer()
      }
      .padding(8)
      HStack(spacing: 10) {
        Button(clip.isPlaying ? "Pause" : "Play", systemImage: clip.isPlaying ? "pause.fill" : "play.fill") { clip.toggle() }
          .labelStyle(.iconOnly).buttonStyle(.kit).controlSize(.small)
        Text(time(clip.position)).kitFont(.caption).monospacedDigit().foregroundStyle(.white)
        KitSlider("Position", value: Binding { clip.position } set: { clip.seek($0) }, in: 0...max(clip.duration, 0.1))
        Text(time(clip.duration)).kitFont(.caption).monospacedDigit().foregroundStyle(.white)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
      .disabled(clip.file == nil)
    }
  }

  private func time(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
#endif
