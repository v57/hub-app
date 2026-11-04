//
//  Camera kit.swift
//  Hub
//
//  The pieces the camera pages need that ComponentKit doesn't have yet (kit-gaps 97–105): labels on a video
//  (VideoChip), the motion box and the motion zone drawn in the picture's own space, a clip's thumbnail, a day's
//  timeline of events, a live level against a threshold, a usage table and a budget meter. Built here until the kit
//  takes them.
//

#if canImport(ComponentKit) && canImport(PlatformCamera)
import SwiftUI
import ComponentKit
import PlatformCamera

// MARK: - On the video

/// A label on a video: white on a dark capsule, orange for motion, with a red dot for live and recording
struct VideoChip: View {
  enum Tone {
    case plain, live, motion, recording
  }
  let title: String
  var systemImage: String?
  var tone = Tone.plain

  var body: some View {
    HStack(spacing: 4) {
      if tone == .live || tone == .recording {
        Circle().fill(Color.red).frame(width: 6, height: 6)
      }
      if let systemImage {
        Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
      }
      Text(title).font(.system(size: 11, weight: .semibold)).monospacedDigit().lineLimit(1)
    }
    .padding(.horizontal, 7)
    .frame(height: 20)
    .foregroundStyle(.white)
    .background(Capsule().fill(tone == .motion ? Color.orange : Color.black.opacity(0.55)))
  }
}

/// Lays `content` over the part of the view an aspect-fit picture covers, so boxes in parts of the picture land on it
struct PictureSpace<Content: View>: View {
  var aspect: CGFloat
  @ViewBuilder var content: Content

  var body: some View {
    GeometryReader { proxy in
      let size = Self.fit(aspect, in: proxy.size)
      content
        .frame(width: size.width, height: size.height)
        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }

  static func fit(_ aspect: CGFloat, in size: CGSize) -> CGSize {
    guard aspect > 0, size.width > 0, size.height > 0 else { return size }
    return size.width / size.height > aspect
      ? CGSize(width: size.height * aspect, height: size.height)
      : CGSize(width: size.width, height: size.width / aspect)
  }
}

/// Where motion is in the picture: an orange box (KitMotionBox)
struct MotionBox: View {
  let box: CameraBox

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.orange.opacity(0.12))
        .strokeBorder(Color.orange, lineWidth: 2)
        .frame(width: max(8, size.width * box.width), height: max(8, size.height * box.height))
        .offset(x: size.width * box.x, y: size.height * box.y)
    }
    .allowsHitTesting(false)
    .animation(.easeOut(duration: 0.2), value: box)
  }
}

/// The motion zone on a preview (KitZoneOverlay): outside it dimmed; while editing, dragged by its body and corners
struct ZoneEditor: View {
  @Binding var zone: MotionDetector.Zone
  var isEditing: Bool
  @State private var start: MotionDetector.Zone?

  private enum Corner: CaseIterable, Identifiable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    var id: Self { self }
  }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let rect = CGRect(
        x: zone.x * size.width, y: zone.y * size.height, width: zone.width * size.width, height: zone.height * size.height)
      ZStack(alignment: .topLeading) {
        Path { path in
          path.addRect(CGRect(origin: .zero, size: size))
          path.addRect(rect)
        }
        .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: isEditing ? [] : [6, 4]))
          .contentShape(Rectangle())
          .frame(width: rect.width, height: rect.height)
          .offset(x: rect.minX, y: rect.minY)
          .gesture(move(in: size), including: isEditing ? .all : .none)
        if isEditing {
          ForEach(Corner.allCases) { corner in
            Circle().fill(Color.yellow).frame(width: 12, height: 12)
              .padding(8)
              .contentShape(Rectangle())
              .position(point(corner, of: rect))
              .gesture(resize(corner, in: size))
          }
        }
      }
    }
  }

  private func point(_ corner: Corner, of rect: CGRect) -> CGPoint {
    switch corner {
    case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
    case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
    case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
    case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
    }
  }

  private func move(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { drag in
        let from = start ?? zone
        start = from
        zone.x = min(max(from.x + drag.translation.width / size.width, 0), 1 - from.width)
        zone.y = min(max(from.y + drag.translation.height / size.height, 0), 1 - from.height)
      }
      .onEnded { _ in start = nil }
  }

  private func resize(_ corner: Corner, in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { drag in
        let from = start ?? zone
        start = from
        let dx = drag.translation.width / size.width
        let dy = drag.translation.height / size.height
        let smallest = 0.1
        var left = from.x, top = from.y, right = from.x + from.width, bottom = from.y + from.height
        switch corner {
        case .topLeading: left += dx; top += dy
        case .topTrailing: right += dx; top += dy
        case .bottomLeading: left += dx; bottom += dy
        case .bottomTrailing: right += dx; bottom += dy
        }
        left = min(max(left, 0), right - smallest)
        top = min(max(top, 0), bottom - smallest)
        right = max(min(right, 1), left + smallest)
        bottom = max(min(bottom, 1), top + smallest)
        zone = MotionDetector.Zone(x: left, y: top, width: right - left, height: bottom - top)
      }
      .onEnded { _ in start = nil }
  }
}

/// A clip's still in a row (KitThumbnail): 16:9, black while there is none
struct CameraThumbnail: View {
  let data: Data?
  var width: CGFloat = 64

  var body: some View {
    ZStack {
      Color.black.opacity(0.75)
      KitImageData(data: data) {
        Image(systemName: "video").font(.system(size: width / 5)).foregroundStyle(.white.opacity(0.45))
      }
      .aspectRatio(16 / 9, contentMode: .fill)
    }
    .frame(width: width, height: width * 9 / 16)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

// MARK: - Timeline

/// A day of events (KitEventTimeline): hours along a track, each event a mark, the playhead, and Live at its end
struct EventTimeline: View {
  struct Mark: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date
  }
  let day: DateInterval
  let marks: [Mark]
  var selected: String?
  /// Where the clip playing is, while one plays
  var playhead: Date?
  var isLive: Bool
  let select: (String) -> Void
  let live: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 4) {
        GeometryReader { proxy in
          let width = proxy.size.width
          ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(.kitFill)
            // The rest of today hasn't happened yet
            let now = x(Date(), width)
            if now < width {
              RoundedRectangle(cornerRadius: 6).fill(.kitFillSoft)
                .frame(width: width - now).offset(x: now)
            }
            ForEach(marks) { mark in
              let start = x(mark.start, width)
              let isSelected = mark.id == selected
              RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Hue.red.fill : Hue.orange.fill)
                .frame(width: max(4, x(mark.end, width) - start), height: isSelected ? 22 : 16)
                .offset(x: start)
            }
            if let playhead {
              Capsule().fill(.kitLabel).frame(width: 2, height: 30).offset(x: x(playhead, width) - 1)
            } else if isLive, now <= width {
              Capsule().fill(Color.red).frame(width: 2, height: 30).offset(x: now - 1)
            }
          }
          .frame(height: 30)
          .contentShape(Rectangle())
          .onTapGesture { location in
            // The nearest mark within a few points of the tap
            let nearest = marks.min { abs(center($0, width) - location.x) < abs(center($1, width) - location.x) }
            if let nearest, abs(center(nearest, width) - location.x) < 14 { select(nearest.id) }
          }
        }
        .frame(height: 30)
        HStack {
          ForEach(Array(hours.enumerated()), id: \.offset) { index, hour in
            if index > 0 { Spacer(minLength: 0) }
            Text(hour).kitFont(.caption).monospacedDigit()
          }
        }
      }
      Button(isLive ? "Live" : "Go Live", systemImage: "dot.radiowaves.left.and.right") { live() }
        .buttonStyle(.kit).controlSize(.small)
        .disabled(isLive)
    }
  }

  private var hours: [String] {
    stride(from: 0, through: 24, by: 6).map { String(format: "%02d:00", $0) }
  }

  private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
    let fraction = date.timeIntervalSince(day.start) / max(day.duration, 1)
    return width * min(max(fraction, 0), 1)
  }

  private func center(_ mark: Mark, _ width: CGFloat) -> CGFloat {
    (x(mark.start, width) + x(mark.end, width)) / 2
  }
}

// MARK: - Meters

/// A live level against a threshold (KitLevelMeter): green under the line, orange over it. Both 0…1 of the bar.
struct LevelMeter: View {
  let level: Double
  let threshold: Double

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.kitFill).frame(height: 8)
        Capsule().fill(level >= threshold ? Hue.orange.fill : Hue.green.fill)
          .frame(width: max(4, width * min(max(level, 0), 1)), height: 8)
        Capsule().fill(.kitLabel).frame(width: 2, height: 16).offset(x: width * min(max(threshold, 0), 1) - 1)
      }
      .frame(height: 16)
      .animation(.linear(duration: 0.25), value: level)
    }
    .frame(height: 16)
  }
}

/// What the system says something costs (KitBudgetMeter): 1.0 is the full bar, orange from 0.8, red past 1.0, with a
/// tick where it was before the last change
struct BudgetMeter: View {
  let title: String
  var detail: String?
  let value: Double?
  var previous: Double?
  /// The value as shown; two decimals by default
  var text: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title).kitFont(.body)
        Spacer()
        Text(text ?? value.map { String(format: "%.2f", $0) } ?? "–")
          .kitFont(.callout).monospacedDigit().foregroundStyle(hue.text)
      }
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(.kitFill).frame(height: 6)
          if let value {
            Capsule().fill(hue.fill).frame(width: max(4, width * min(value, 1)), height: 6)
          }
          if let previous {
            Capsule().fill(.kitSecondary).frame(width: 2, height: 12).offset(x: width * min(max(previous, 0), 1) - 1)
          }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.3), value: value)
      }
      .frame(height: 12)
      if let detail { Text(detail).kitFont(.caption) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private var hue: Hue {
    guard let value else { return .gray }
    return value > 1 ? .red : value >= 0.8 ? .orange : .green
  }
}

/// Per second, per day and per month (KitUsageTable)
struct UsageTable: View {
  struct Row: Identifiable {
    var id: String { name }
    let name: String
    let detail: String
    let second: String
    let day: String
    let month: String
  }
  let rows: [Row]

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
      GridRow {
        Color.clear.frame(height: 1)
        Text("Per second").gridColumnAlignment(.trailing)
        Text("Per day").gridColumnAlignment(.trailing)
        Text("Per month").gridColumnAlignment(.trailing)
      }
      .kitFont(.caption)
      ForEach(rows) { row in
        GridRow {
          VStack(alignment: .leading, spacing: 1) {
            Text(row.name).kitFont(.body)
            Text(row.detail).kitFont(.caption)
          }
          Text(row.second)
          Text(row.day)
          Text(row.month)
        }
        .kitFont(.callout)
        .monospacedDigit()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

// MARK: - Formats

enum CameraFormat {
  static func bytes(_ count: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }

  static func rate(_ bytesPerSecond: Double) -> String {
    bytes(bytesPerSecond) + "/s"
  }

  static func bitrate(_ bits: Int) -> String {
    bits >= 1_000_000 ? String(format: "%.1f Mbit/s", Double(bits) / 1_000_000) : "\(bits / 1000) kbit/s"
  }

  static func duration(_ seconds: Double) -> String {
    Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
  }

  /// The meter's place of a motion level (the share of the picture that changed), on a log scale from 0.1% to all of
  /// it, so the thresholds (0.3%…6%) sit in the middle of the bar
  static func meter(_ level: Double) -> Double {
    guard level > 0.001 else { return 0 }
    return min(log10(level / 0.001) / 3, 1)
  }
}
#endif
