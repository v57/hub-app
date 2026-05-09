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
    dragging || hovering ? 0.3 : 0
  }
  var scale: Double {
    dragging ? 0.9 : hovering ? 1.05 : 1.0
  }
  @GestureState var dragState: Bool = false
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
        Color.black.opacity(0.001).onContinuousHover { phase in
          switch phase {
          case .active(let point):
            withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
              update(position: point, size: view.size)
              hovering = true
            }
          case .ended:
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
              offset = .zero
              hovering = false
            }
          }
        }.simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).updating($dragState) { _, state, _ in
          state = true
        }.onChanged { gesture in
          if !hovering {
            withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
              update(position: gesture.location, size: view.size)
            }
          }
        })
      }
    }.onChange(of: dragState) {
      withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
        dragging = dragState
        if !dragState && !hovering {
          offset = .zero
        }
      }
    }
  }
  func update(position: CGPoint, size: CGSize) {
    let x = position.x / size.width - 0.5
    let y = position.y / size.height - 0.5
    offset = CGPoint(x: max(min(x, 0.5), -0.5), y: max(min(y, 0.5), -0.5))
  }
}

#Preview {
  HStack(spacing: 24) {
    RoundedRectangle(cornerRadius: 16).fill(.white)
      .frame(width: 64, height: 64)
      .overlay {
        Image(systemName: "greetingcard.fill")
          .font(.system(size: 36))
      }.modifier(HoverModifier())
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
  }.frame(maxWidth: .infinity, maxHeight: .infinity)
}
