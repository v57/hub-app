//
//  Hover.swift
//  Hub
//
//  Created by Linux on 09.05.26.
//

import SwiftUI

extension View {
  func hoverEffect() -> some View {
    modifier(HoverModifier())
  }
}

struct HoverModifier: ViewModifier {
  @Environment(\.colorScheme) var scheme
  @State var hovering: Bool = false
  @State var dragging: Bool = false
  @State var offset: CGPoint = .zero
  @State var size: CGSize = CGSize(width: 1, height: 1)
  var rotation: Double { 8 }
  var offsetMultiplier: Double { 8 }
  var gradientOpacity: Double {
    if scheme == .dark {
      dragging || hovering ? 0.2 : 0
    } else {
      dragging || hovering ? 1 : 0
    }
  }
  var gradientEndOpacity: Double {
    if scheme == .dark {
      dragging || hovering ? 0.02 : 0
    } else {
      dragging || hovering ? 0 : 0
    }
  }
  var endRadius: Double {
    if scheme == .dark {
      hovering || dragging ? 64 : 200
    } else {
      hovering || dragging ? 32 : 200
    }
  }
  var scale: Double {
    dragging ? 1.1 : hovering ? 1.05 : 1.0
  }
  var zIndex: Double {
    dragging || hovering ? -4 : 0
  }
  var gradient: RadialGradient {
    RadialGradient(colors: [
      .white.opacity(gradientOpacity),
      .white.opacity(gradientEndOpacity)
    ], center: UnitPoint(x: offset.x * 0.9 + 0.5, y: offset.y * 0.9 + 0.5), startRadius: 0, endRadius: endRadius)
  }
  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: 16).fill(gradient)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .allowsHitTesting(false)
    }
    .rotation3DEffect(.degrees(-offset.y * rotation), axis: (x: 1, y: 0, z: 0), anchorZ: zIndex)
    .rotation3DEffect(.degrees(offset.x * rotation), axis: (x: 0, y: 1, z: 0), anchorZ: zIndex)
    .compositingGroup()
    .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.1), radius: hovering ? 12 : 10)
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
#elseif os(macOS)
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

#Preview {
  ScrollView {
    HStack(spacing: 24) {
      Button {
        print("Button touched")
      } label: {
        RoundedRectangle(cornerRadius: 16).fill(.background)
          .frame(width: 64, height: 64)
          .overlay {
            Image(systemName: "greetingcard.fill")
              .font(.system(size: 36))
          }.modifier(HoverModifier())
      }
      RoundedRectangle(cornerRadius: 16).fill(.background)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "square.and.arrow.up.circle.fill")
            .font(.system(size: 48))
        }.modifier(HoverModifier())
      RoundedRectangle(cornerRadius: 16).fill(.background)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "waveform.path.ecg.text.clipboard")
            .font(.system(size: 36))
        }.modifier(HoverModifier())
      RoundedRectangle(cornerRadius: 16).fill(.background)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "trash.circle.fill")
            .font(.system(size: 48))
        }.modifier(HoverModifier())
    }
    Color.clear.frame(height: 2000)
  }.buttonStyle(.plain)
}
