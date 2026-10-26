//
//  NetworkMap.swift
//  Hub
//
//  The Network page's map: the hub in the middle and its devices around it. It keeps its size as the network grows:
//  up to 6 devices each one is named with its line; then dots on one ring, three rings around 100, five around 400
//  (smaller dots), and past that counts only. This device and the one whose internet is in use stay named.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit

struct NetworkMap: View {
  let hubName: String
  /// This device, named on the left
  let thisDevice: NetDevice?
  /// The other devices
  let devices: [NetDevice]
  /// The device whose internet is in use, named on the right once the others are dots
  var internet: NetDevice?
  var isOn = true
  var isConnecting = false
  var height: CGFloat = 156
  @State private var hovered: (name: String, point: CGPoint)?

  /// Named nodes up to this many devices in all, this one included
  static let namedLimit = 6
  /// Dots up to this many; counts only past it
  static let dotLimit = 500

  private enum Mode { case named, rings(Int, CGFloat), counts }

  private var mode: Mode {
    let count = devices.count + 1
    if count <= Self.namedLimit { return .named }
    if count <= 24 { return .rings(1, 8) }
    if count <= 130 { return .rings(3, 8) }
    if count <= Self.dotLimit { return .rings(5, 6) }
    return .counts
  }

  var body: some View {
    VStack(spacing: 6) {
      GeometryReader { geometry in
        let size = geometry.size
        let center = CGPoint(x: size.width / 2, y: size.height * 0.46)
        ZStack {
          switch mode {
          case .named:
            named(size: size, center: center)
          case .rings(let rings, let dot):
            dots(size: size, center: center, rings: rings, dot: dot)
          case .counts:
            counts(size: size, center: center)
          }
          hubNode.position(center)
          if let hovered {
            Text(hovered.name).kitFont(.caption).foregroundStyle(.kitLabel)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .kitSurface(.card, cornerRadius: 6)
              .position(x: hovered.point.x, y: hovered.point.y - 14)
              .allowsHitTesting(false)
          }
        }
      }
      .frame(height: height)
      if case .named = mode {} else {
        legend
      }
    }
    .opacity(isOn ? 1 : 0.5)
    .animation(.kit, value: isOn)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  // MARK: Named

  /// Where each other device sits around the hub, as fractions of the map
  private static let slots: [CGPoint] = [
    CGPoint(x: 0.88, y: 0.26), CGPoint(x: 0.3, y: 0.84), CGPoint(x: 0.74, y: 0.86), CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.36, y: 0.12),
  ]

  private func named(size: CGSize, center: CGPoint) -> some View {
    let thisPoint = CGPoint(x: size.width * 0.1, y: size.height * 0.4)
    let others = Array(devices.prefix(Self.slots.count))
    let points = others.indices.map { CGPoint(x: Self.slots[$0].x * size.width, y: Self.slots[$0].y * size.height) }
    return ZStack {
      Canvas { context, _ in
        if let thisDevice { line(context, from: center, to: thisPoint, status: thisDevice.status) }
        for (index, device) in others.enumerated() {
          line(context, from: center, to: points[index], status: device.status)
        }
      }
      if let thisDevice {
        VStack(spacing: 3) {
          Image(systemName: thisDevice.symbol).font(.system(size: 14)).foregroundStyle(.kitLabel)
          Text("This \(KitDevice.name)").kitFont(.caption).fontWeight(.semibold).foregroundStyle(.kitLabel)
        }
        .position(thisPoint)
      }
      ForEach(Array(others.enumerated()), id: \.element.id) { index, device in
        node(device).position(points[index])
      }
    }
  }

  private func node(_ device: NetDevice) -> some View {
    VStack(spacing: 3) {
      Image(systemName: device.symbol)
        .font(.system(size: 13))
        .foregroundStyle(device.status == .cantReach ? AnyShapeStyle(Hue.orange.text) : AnyShapeStyle(.kitLabel))
        .frame(width: 32, height: 32)
        .background(Circle().fill(.kitCard))
        .overlay(Circle().strokeBorder(device.status == .cantReach ? AnyShapeStyle(Hue.orange.fill) : AnyShapeStyle(.kitSeparator), lineWidth: 1))
      Text(device.name).kitFont(.caption).lineLimit(1).fixedSize()
    }
    .opacity(device.status == .asleep ? 0.6 : 1)
  }

  private var hubNode: some View {
    VStack(spacing: 3) {
      Image(systemName: "hexagon")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(Hue.red.text)
        .frame(width: 44, height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Hue.red.fill.opacity(0.18)))
        .overlay {
          if isConnecting {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Hue.orange.fill, lineWidth: 1.5)
              .modifier(Pulse())
          }
        }
      Text(hubName).kitFont(.caption).fontWeight(.semibold).foregroundStyle(.kitLabel).lineLimit(1).fixedSize()
    }
    .offset(y: 9)
  }

  private func line(_ context: GraphicsContext, from: CGPoint, to: CGPoint, status: NetDevice.Status) {
    var path = Path()
    path.move(to: from)
    path.addLine(to: to)
    let (style, dashed): (AnyShapeStyle, Bool) = switch status {
    case _ where isConnecting: (AnyShapeStyle(.kitTertiary), true)
    case .thisDevice, .online: (AnyShapeStyle(Hue.green.fill), false)
    case .cantReach: (AnyShapeStyle(Hue.orange.fill), true)
    case .asleep, .off: (AnyShapeStyle(.kitTertiary), true)
    }
    context.stroke(path, with: .style(style), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [4, 4] : []))
  }

  // MARK: Dots

  private func ringPoints(size: CGSize, center: CGPoint, rings: Int, dot: CGFloat) -> [(NetDevice, CGPoint)] {
    // Rings between the hub and the named devices; the outer ones hold more
    let ordered = devices.filter { $0.id != internet?.id }
    let maxX = size.width * 0.3, maxY = size.height * 0.46
    let minX: CGFloat = 62, minY: CGFloat = 54
    var radii = [(CGFloat, CGFloat)]()
    for ring in 0..<rings {
      let t = rings == 1 ? 1 : CGFloat(ring) / CGFloat(rings - 1)
      radii.append((minX + (maxX - minX) * t, minY + (maxY - minY) * t))
    }
    let circumferences = radii.map { 2 * .pi * sqrt(($0.0 * $0.0 + $0.1 * $0.1) / 2) }
    let total = circumferences.reduce(0, +)
    var result = [(NetDevice, CGPoint)]()
    var index = 0
    for (ring, radius) in radii.enumerated() {
      let share = ring == rings - 1 ? ordered.count - index : Int((CGFloat(ordered.count) * circumferences[ring] / total).rounded())
      let count = max(0, min(share, ordered.count - index))
      for step in 0..<count {
        // Half a step off the horizontal, where the named devices' lines run
        let angle = 2 * .pi * (CGFloat(step) + 0.5) / CGFloat(max(count, 1)) + CGFloat(ring) * 0.21
        result.append((ordered[index], CGPoint(x: center.x + radius.0 * cos(angle), y: center.y + radius.1 * sin(angle))))
        index += 1
      }
    }
    return result
  }

  private func dots(size: CGSize, center: CGPoint, rings: Int, dot: CGFloat) -> some View {
    let points = ringPoints(size: size, center: center, rings: rings, dot: dot)
    let thisPoint = CGPoint(x: size.width * 0.08, y: center.y)
    let internetPoint = CGPoint(x: size.width * 0.92, y: center.y)
    return ZStack {
      Canvas { context, _ in
        if thisDevice != nil { line(context, from: center, to: thisPoint, status: isOn ? .online : .off) }
        if let internet { line(context, from: center, to: internetPoint, status: internet.status) }
        for (device, point) in points {
          let rect = CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)
          switch device.status {
          case .asleep, .off:
            context.stroke(Path(ellipseIn: rect.insetBy(dx: 0.75, dy: 0.75)), with: .style(.kitTertiary), lineWidth: 1.2)
          case .cantReach:
            context.fill(Path(ellipseIn: rect), with: .style(Hue.orange.fill))
          case .online, .thisDevice:
            context.fill(Path(ellipseIn: rect), with: .style(Hue.green.fill))
          }
        }
      }
      if let thisDevice {
        VStack(spacing: 3) {
          Image(systemName: thisDevice.symbol).font(.system(size: 13)).foregroundStyle(.kitLabel)
          Text("This \(KitDevice.name)").kitFont(.caption).fontWeight(.semibold).foregroundStyle(.kitLabel).fixedSize()
        }
        .background(Circle().fill(.kitCard).frame(width: 30, height: 30))
        .position(x: thisPoint.x, y: thisPoint.y + 6)
      }
      if let internet {
        node(internet).position(x: internetPoint.x, y: internetPoint.y + 8)
      }
    }
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let location):
        let nearest = points.min { distance($0.1, location) < distance($1.1, location) }
        if let nearest, distance(nearest.1, location) < dot + 3 {
          hovered = (nearest.0.name, nearest.1)
        } else {
          hovered = nil
        }
      case .ended:
        hovered = nil
      }
    }
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

  // MARK: Counts

  private func counts(size: CGSize, center: CGPoint) -> some View {
    let thisPoint = CGPoint(x: size.width * 0.12, y: center.y)
    return ZStack {
      Canvas { context, _ in
        if thisDevice != nil { line(context, from: center, to: thisPoint, status: isOn ? .online : .off) }
        for ring in 0..<3 {
          let inset = CGFloat(ring) * 16
          let rect = CGRect(x: center.x - size.width * 0.3 + inset, y: center.y - size.height * 0.44 + inset * 0.7,
                            width: (size.width * 0.3 - inset) * 2, height: (size.height * 0.44 - inset * 0.7) * 2)
          context.stroke(Path(ellipseIn: rect), with: .style(Hue.green.fill.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
        }
      }
      if thisDevice != nil {
        Text("This \(KitDevice.name)").kitFont(.caption).fontWeight(.semibold).position(x: thisPoint.x, y: thisPoint.y + 14)
      }
      Text("\(devices.count + 1) devices").kitFont(.title3).position(x: size.width * 0.84, y: center.y)
    }
  }

  // MARK: Legend

  private var legend: some View {
    let online = devices.filter { $0.status == .online }.count
    let asleep = devices.filter { $0.status == .asleep || $0.status == .off }.count
    let unreachable = devices.filter { $0.status == .cantReach }.count
    return HStack(spacing: 12) {
      if !isOn {
        // Off, this device can't tell who is online
        HStack(spacing: 4) { StatusDot(hue: .gray, isHollow: true, size: 7); Text(devices.count == 1 ? "1 device" : "\(devices.count) devices") }
      } else {
        HStack(spacing: 4) { StatusDot(hue: .green, size: 7); Text("\(online) online") }
        HStack(spacing: 4) { StatusDot(hue: .gray, isHollow: true, size: 7); Text("\(asleep) asleep") }
        if unreachable > 0 {
          HStack(spacing: 4) { StatusDot(hue: .orange, size: 7); Text("\(unreachable) can’t reach") }
        }
      }
    }
    .kitFont(.caption)
  }

  private var accessibilityText: String {
    let others = devices.count
    return "\(hubName) and \(others == 1 ? "1 device" : "\(others) devices")"
  }
}

/// A slow pulse, for the hub while this device connects
private struct Pulse: ViewModifier {
  @State private var on = false
  func body(content: Content) -> some View {
    content.opacity(on ? 1 : 0.2)
      .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
  }
}
#endif
