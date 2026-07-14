//
//  Hover.swift
//  Hub
//
//  Created by Linux on 09.05.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

extension View {
  func hoverEffect<S: InsettableShape>(in shape: S) -> some View {
    modifier(HoverModifier(shape: shape))
  }
  func disableHoverScale() -> some View {
    preference(key: DisableScalePreference.self, value: true)
  }
}

struct HoverModifier<S: InsettableShape>: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isPressed) private var isPressed
  @Environment(\.innerHover) private var innerHover
  @Environment(\.displayScale) private var scale
  
  let shape: S
  
  @State private var hovering: Bool = false
  @State private var dragging: Bool = false
  @State private var offset: CGPoint = .zero
  @State private var size: CGSize = CGSize(width: 1, height: 1)
  @State private var innerActive = false
  @State private var hoverScale = true
  private var rotation: Double { 8 }
  private var offsetMultiplier: Double { innerHover ? 2 : 8 }
  private var isActive: Bool { hovering || dragging }
  private var isDark: Bool { scheme == .dark }
  private var gradientOpacity: Double {
    if innerActive {
      return 0.05
    } else if isDark {
      return isPressed ? 0.2 : isActive ? 0.1 : 0
    } else {
      return isPressed ? 0.5 : isActive ? 1 : 0
    }
  }
  private var gradientEndOpacity: Double {
    if innerActive {
      return 0.01
    } else if isDark {
      return isActive ? 0.02 : 0
    } else {
      return isActive ? 0 : 0
    }
  }
  private var endRadius: Double {
    if innerActive {
      return 32
    } else if isPressed || !isActive {
      return 200
    } else if isDark {
      return 64
    } else {
      return 32
    }
  }
  private var hoverZIndex: Double {
    isLowResolution ? 0 : innerHover ? -4 : -8
  }
  private var touchZIndex: Double {
    innerHover ? -5 : -10
  }
  private var zIndex: Double {
    if isLowResolution || !hoverScale {
      return 0
    } else if isPressed {
      return touchZIndex
    } else if isActive {
      return hoverZIndex
    } else {
      return 0
    }
  }
  private var verticalAngle: Angle { isLowResolution || !hoverScale ? .degrees(0) : .degrees(-offset.y * rotation) }
  private var horizontalAngle: Angle { isLowResolution || !hoverScale ? .degrees(0) : .degrees(offset.x * rotation) }
  private var isLowResolution: Bool { scale < 1.5 }
  
  
  var gradient: RadialGradient {
    RadialGradient(colors: [
      .white.opacity(gradientOpacity),
      .white.opacity(gradientEndOpacity)
    ], center: UnitPoint(x: offset.x * 0.9 + 0.5, y: offset.y * 0.9 + 0.5), startRadius: 0, endRadius: endRadius * interfaceScale)
  }
  var strokeGradient: RadialGradient {
    RadialGradient(colors: [
      .primary.opacity(isActive ? 1 : 0),
      .primary.opacity(isActive ? 0 : 0)
    ], center: UnitPoint(x: offset.x * 0.9 + 0.5, y: offset.y * 0.9 + 0.5), startRadius: 0, endRadius: (isPressed ? 64 : isActive ? 32 : 200) * interfaceScale)
  }
  func body(content: Content) -> some View {
    content.environment(\.innerHover, true).onPreferenceChange(HoverInnerPreference.self) { isActive in
      withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
        self.innerActive = isActive
      }
    }.overlay {
      shape.fill(gradient)
        .strokeBorder(strokeGradient, lineWidth: 1)
        .allowsHitTesting(false)
    }
    .glassStyle(in: shape)
    .rotation3DEffect(verticalAngle, axis: (x: 1, y: 0, z: 0), anchorZ: zIndex)
    .rotation3DEffect(horizontalAngle, axis: (x: 0, y: 1, z: 0), anchorZ: zIndex)
    .offset(x: offset.x * offsetMultiplier, y: offset.y * offsetMultiplier)
    .background {
      GeometryReader { view in
        Color.clear.hidden().task(id: view.size) {
          size = view.size
        }
      }
    }.preference(key: HoverInnerPreference.self, value: isActive)
      .modifier(HoverEvents(hovering: $hovering, dragging: $dragging, offset: $offset, size: size))
      .onPreferenceChange(DisableScalePreference.self) { hoverScale = !$0 }
  }
  struct HoverEvents: ViewModifier {
    @Binding var hovering: Bool
    @Binding var dragging: Bool
    @Binding var offset: CGPoint
    let size: CGSize
    func body(content: Content) -> some View {
#if os(iOS)
      if #available(iOS 18.0, *) {
        content.onContinuousHover {
          hover(phase: $0, size: size)
        }.gesture(gesture(size: size))
      } else {
        content.onContinuousHover {
          hover(phase: $0, size: size)
        }
      }
#elseif os(visionOS)
      content.hoverEffect { view, isActive, size in
        view.scaleEffect(isActive ? visionScale() : 1)
      }
#else
      content.onContinuousHover {
        hover(phase: $0, size: size)
      }
#endif
    }
#if os(iOS)
    func gesture(size: CGSize) -> SimultaneousGesture {
      SimultaneousGesture {
        withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
          dragging = true
        }
      } onChanged: { point in
        if !hovering {
          withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
            update(position: point, size: size)
          }
        }
      } onEnded: {
        withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
          dragging = false
          if !hovering {
            offset = .zero
          }
        }
      }
    }
#endif
    func visionScale() -> CGFloat {
      let value = max(size.width, size.height)
      return (value + 8) / value
    }
    func hover(phase: HoverPhase, size: CGSize) {
      switch phase {
      case .active(let point):
        withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
          update(position: point, size: size)
          hovering = true
        }
      case .ended:
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
          offset = .zero
          hovering = false
        }
      }
    }
    func update(position: CGPoint, size: CGSize) {
      let x = position.x / size.width - 0.5
      let y = position.y / size.height - 0.5
      offset = CGPoint(x: max(min(x, 0.5), -0.5), y: max(min(y, 0.5), -0.5))
    }
  }
}
struct HoverInnerPreference: PreferenceKey {
  static var defaultValue: Bool { false }
  static func reduce(value: inout Value, nextValue: () -> Value) {
    value = value || nextValue()
  }
}
struct DisableScalePreference: PreferenceKey {
  static var defaultValue: Bool { false }
  static func reduce(value: inout Value, nextValue: () -> Value) {
    guard !value else { return }
    if nextValue() {
      value = true
    }
  }
}

#if os(iOS)
struct SimultaneousGesture: UIGestureRecognizerRepresentable {
  let onBegan: () -> Void
  let onChanged: (CGPoint) -> Void
  let onEnded: () -> Void

  init(onBegan: @escaping () -> Void,
     onChanged: @escaping (CGPoint) -> Void,
     onEnded: @escaping () -> Void) {
    self.onBegan = onBegan
    self.onChanged = onChanged
    self.onEnded = onEnded
  }
  
  func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
    let gesture = UILongPressGestureRecognizer()
    gesture.minimumPressDuration = 0.0
    gesture.allowableMovement = CGFloat.greatestFiniteMagnitude
    gesture.delegate = context.coordinator
    return gesture
  }
  
  func handleUIGestureRecognizerAction(_ gesture: UILongPressGestureRecognizer, context: Context) {
    switch gesture.state {
    case .began:
      onBegan()
      onChanged(context.converter.localLocation)
    case .changed:
      onChanged(context.converter.localLocation)
    case .ended, .cancelled:
      onEnded()
    default: break
    }
  }
  
  func updateUIGestureRecognizer(_ gesture: UILongPressGestureRecognizer, context: Context) { }
  
  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
    Coordinator()
  }
  
  class Coordinator: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      return true
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      return true
    }
  }
}
#endif

extension ButtonStyle where Self == EnvironmentButtonStyle {
  static var environment: EnvironmentButtonStyle { EnvironmentButtonStyle() }
}

struct EnvironmentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.environment(\.isPressed, configuration.isPressed)
      .animation(.smooth(duration: 0.25), value: configuration.isPressed)
  }
}
extension EnvironmentValues {
  var isPressed: Bool {
    get { self[IsPressed.self] }
    set { self[IsPressed.self] = newValue }
  }
  var innerHover: Bool {
    get { self[InnerHover.self] }
    set { self[InnerHover.self] = newValue }
  }
  private struct IsPressed: EnvironmentKey {
    static var defaultValue: Bool { false }
  }
  private struct InnerHover: EnvironmentKey {
    static var defaultValue: Bool { false }
  }
}

#Preview {
  ScrollView {
    HStack(spacing: 24) {
      Button {
        print("Button touched")
      } label: {
        RoundedRectangle(cornerRadius: 16).fill(.clear)
          .frame(width: 64, height: 64)
          .overlay {
            Image(systemName: "greetingcard.fill")
              .font(.system(size: 36))
          }.hoverEffect(in: .rounded(16))
      }
      RoundedRectangle(cornerRadius: 16).fill(.clear)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "square.and.arrow.up.circle.fill")
            .font(.system(size: 48))
        }.hoverEffect(in: .rounded(16))
      RoundedRectangle(cornerRadius: 16).fill(.clear)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "waveform.path.ecg.text.clipboard")
            .font(.system(size: 36))
        }.hoverEffect(in: .rounded(16))
      RoundedRectangle(cornerRadius: 16).fill(.clear)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "trash.circle.fill")
            .font(.system(size: 48))
        }.hoverEffect(in: .rounded(16))
    }.buttonStyle(.environment)
    Color.clear.frame(height: 2000)
  }.buttonStyle(.plain)
}
