//
//  Hover.swift
//  Hub
//
//  Created by Linux on 09.05.26.
//

import SwiftUI

extension View {
  func hoverEffect<S: InsettableShape>(in shape: S) -> some View {
    modifier(HoverModifier(shape: shape))
  }
  func hoverEffect() -> some View {
    modifier(HoverModifier(shape: RoundedRectangle(cornerRadius: 16)))
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
  private var rotation: Double { 8 }
  private var offsetMultiplier: Double { innerHover ? 2 : 8 }
  private var isActive: Bool { hovering || dragging }
  private var isDark: Bool { scheme == .dark }
  private var gradientOpacity: Double {
    if innerHover {
      return 0
    } else if isDark {
      return isPressed ? 0.3 : isActive ? 0.2 : 0
    } else {
      return isPressed ? 0.5 : isActive ? 1 : 0
    }
  }
  private var gradientEndOpacity: Double {
    if innerHover {
      return 0
    } else if isDark {
      return isActive ? 0.02 : 0
    } else {
      return isActive ? 0 : 0
    }
  }
  private var endRadius: Double {
    if isDark {
      isPressed ? 200 : isActive ? 64 : 200
    } else {
      isPressed ? 200 : isActive ? 32 : 200
    }
  }
  private var hoverZIndex: Double {
    isLowResolution ? 0 : innerHover ? -2 : -8
  }
  private var touchZIndex: Double {
    innerHover ? -4 : -10
  }
  private var zIndex: Double { isPressed ? touchZIndex : isActive ? hoverZIndex : 0 }
  private var verticalAngle: Angle { isLowResolution ? .degrees(0) : .degrees(-offset.y * rotation) }
  private var horizontalAngle: Angle { isLowResolution ? .degrees(0) : .degrees(offset.x * rotation) }
  private var isLowResolution: Bool { scale < 1.5 }
  
  
  var gradient: RadialGradient {
    RadialGradient(colors: [
      .white.opacity(gradientOpacity),
      .white.opacity(gradientEndOpacity)
    ], center: UnitPoint(x: offset.x * 0.9 + 0.5, y: offset.y * 0.9 + 0.5), startRadius: 0, endRadius: endRadius)
  }
  var strokeGradient: RadialGradient {
    RadialGradient(colors: [
      .primary.opacity(isActive ? 1 : 0),
      .primary.opacity(isActive ? 0 : 0)
    ], center: UnitPoint(x: offset.x * 0.9 + 0.5, y: offset.y * 0.9 + 0.5), startRadius: 0, endRadius: isPressed ? 64 : isActive ? 32 : 200)
  }
  func body(content: Content) -> some View {
    content.environment(\.innerHover, true).overlay {
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
    }.modifier(HoverEvents(hovering: $hovering, dragging: $dragging, offset: $offset, size: size))
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
          }.hoverEffect()
      }
      RoundedRectangle(cornerRadius: 16).fill(.clear)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "square.and.arrow.up.circle.fill")
            .font(.system(size: 48))
        }.hoverEffect()
      RoundedRectangle(cornerRadius: 16).fill(.clear)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "waveform.path.ecg.text.clipboard")
            .font(.system(size: 36))
        }.hoverEffect()
      RoundedRectangle(cornerRadius: 16).fill(.clear)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "trash.circle.fill")
            .font(.system(size: 48))
        }.hoverEffect()
    }.buttonStyle(.environment)
    Color.clear.frame(height: 2000)
  }.buttonStyle(.plain)
}
