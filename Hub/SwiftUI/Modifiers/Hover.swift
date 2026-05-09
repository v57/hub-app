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
  var rotation: Double { 8 }
  var offsetMultiplier: Double { 8 }
  var gradientOpacity: Double {
    dragging || hovering ? 1 : 0
  }
  var scale: Double {
    dragging ? 1.1 : hovering ? 1.05 : 1.0
  }
  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: 16).fill(RadialGradient(colors: [.white.opacity(gradientOpacity), .clear], center: UnitPoint(x: offset.x * 0.9 + 0.5, y: offset.y * 0.9 + 0.5), startRadius: 0, endRadius: 32))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    .rotation3DEffect(.degrees(-offset.y * rotation), axis: (x: 1, y: 0, z: 0))
    .rotation3DEffect(.degrees(offset.x * rotation), axis: (x: 0, y: 1, z: 0))
    .compositingGroup()
    .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.1), radius: hovering ? 12 : 10)
    .offset(x: offset.x * offsetMultiplier, y: offset.y * offsetMultiplier)
    .scaleEffect(scale)
    .overlay {
      GeometryReader { view in
        #if os(iOS)
        if #available(iOS 18.0, *) {
          Color.black.opacity(0.001).onContinuousHover {
            hover(phase: $0, size: view.size)
          }.gesture(gesture(size: view.size))
        } else {
          Color.black.opacity(0.001).onContinuousHover {
            hover(phase: $0, size: view.size)
          }
        }
        #elseif os(macOS)
        Color.black.opacity(0.001).onContinuousHover {
          hover(phase: $0, size: view.size)
        }
        #endif
      }
    }
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

#Preview {
  ScrollView {
    HStack(spacing: 24) {
      Button {
        print("Button touched")
      } label: {
        RoundedRectangle(cornerRadius: 16).fill(.white)
          .frame(width: 64, height: 64)
          .overlay {
            Image(systemName: "greetingcard.fill")
              .font(.system(size: 36))
          }.modifier(HoverModifier())
      }
      RoundedRectangle(cornerRadius: 16).fill(.white)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "square.and.arrow.up.circle.fill")
            .font(.system(size: 48))
        }.modifier(HoverModifier())
      RoundedRectangle(cornerRadius: 16).fill(.white)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "waveform.path.ecg.text.clipboard")
            .font(.system(size: 36))
        }.modifier(HoverModifier())
      RoundedRectangle(cornerRadius: 16).fill(.white)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "trash.circle.fill")
            .font(.system(size: 48))
        }.modifier(HoverModifier())
    }
    Color.clear.frame(height: 2000)
  }
}
#endif
