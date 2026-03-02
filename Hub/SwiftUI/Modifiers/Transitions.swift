//
//  Transitions.swift
//  Hub
//
//  Created by Linux on 02.03.26.
//

import SwiftUI

extension View {
  func transitionSource<ID: Hashable>(id: ID, namespace: Namespace.ID) -> some View {
    modifier(TransitionSourceModifier(id: id, namespace: namespace))
  }
  func transitionTarget<ID: Hashable>(id: ID, namespace: Namespace.ID) -> some View {
    modifier(TransitionTargetModifier(id: id, namespace: namespace))
  }
}
private struct TransitionSourceModifier<ID: Hashable>: ViewModifier {
  let id: ID
  let namespace: Namespace.ID
  func body(content: Content) -> some View {
    content
//    if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
//      content.matchedTransitionSource(id: id, in: namespace)
//    } else {
//      content
//    }
  }
}

private struct TransitionTargetModifier<ID: Hashable>: ViewModifier {
  let id: ID
  let namespace: Namespace.ID
  func body(content: Content) -> some View {
    #if os(iOS)
    if #available(iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
      content.navigationTransition(.zoom(sourceID: id, in: namespace))
    } else {
      content
    }
    #else
    content
    #endif
  }
}
