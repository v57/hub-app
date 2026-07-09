//
//  Keyboard.swift
//  Hub
//
//  Created by Linux on 24.02.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

extension View {
  func keyboard(style: KeyboardStyle) -> some View {
    modifier(style)
  }
  func scrollDismissesKeyboardImmediately() -> some View {
#if !os(visionOS)
    scrollDismissesKeyboard(.immediately)
#else
    self
#endif
  }
}
enum KeyboardStyle: ViewModifier {
  case url, code
  func body(content: Content) -> some View {
#if canImport(SwiftCrossUI)
    content
#else
    switch self {
    case .url:
#if os(macOS)
      content
        .textContentType(.URL)
        .autocorrectionDisabled()
#else
      content
        .textContentType(.URL)
        .keyboardType(.URL)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
#endif
    case .code:
#if os(macOS)
      content
        .autocorrectionDisabled()
#else
      content
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .keyboardType(.asciiCapable)
#endif
    }
#endif
  }
}
