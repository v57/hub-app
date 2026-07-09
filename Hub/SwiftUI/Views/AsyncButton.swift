//
//  AsyncButton.swift
//  Hub
//
//  Created by Dmitry Kozlov on 2/6/25.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

typealias SwiftUILabel = Label

struct AsyncButton<Label: View>: View {
  let action: @MainActor () async throws -> Void
  let label: Label
  var role: ButtonRole?
  init(action: @MainActor @escaping () async throws -> Void, @ViewBuilder label: () -> Label) {
    self.action = action
    self.label = label()
  }
  @State var isRunning: Bool = false
  var body: some View {
    Button(role: role) {
      guard !isRunning else { return }
      isRunning = true
      Task {
        defer { isRunning = false }
        do {
          try await action()
        } catch {
          print(error)
        }
      }
    } label: { label }.disabled(isRunning)
  }
}
extension AsyncButton where Label == Text {
  init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () async throws -> Void) {
    self.action = action
    self.label = Text(titleKey)
  }
  init<S>(_ title: S, action: @escaping @MainActor () async throws -> Void) where S : StringProtocol {
    self.action = action
    self.label = Text(title)
  }
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
extension AsyncButton where Label == SwiftUILabel<Text, Image> {
  init(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping @MainActor () async throws -> Void) {
    self.action = action
    self.label = Label(titleKey, systemImage: systemImage)
  }
  init<S>(_ title: S, systemImage: String, action: @escaping @MainActor () async throws -> Void) where S : StringProtocol {
    self.action = action
    self.label = Label(title, systemImage: systemImage)
  }
}


@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncButton {
  init(role: ButtonRole?, action: @escaping @MainActor () async throws -> Void, @ViewBuilder label: () -> Label) {
    self.action = action
    self.label = label()
    self.role = role
  }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncButton where Label == Text {
  init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () async throws -> Void) {
    self.action = action
    self.label = Text(titleKey)
    self.role = role
  }
  init<S>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () async throws -> Void) where S : StringProtocol {
    self.action = action
    self.label = Text(title)
    self.role = role
  }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
extension AsyncButton where Label == SwiftUILabel<Text, Image> {
  init(_ titleKey: LocalizedStringKey, systemImage: String, role: ButtonRole?, action: @escaping @MainActor () async throws -> Void) {
    self.action = action
    self.label = Label(titleKey, systemImage: systemImage)
    self.role = role
    
  }
  init<S>(_ title: S, systemImage: String, role: ButtonRole?, action: @escaping @MainActor () async throws -> Void) where S : StringProtocol {
    self.action = action
    self.label = Label(title, systemImage: systemImage)
    self.role = role
  }
}
