//
//  Service selection.swift
//  Hub
//
//  Created by Linux on 31.03.26.
//

import HubService
import SwiftUI

extension View {
  func syncProviders(path: String) -> some View {
    modifier(ServiceProvider.Sync(path: path))
  }
}

extension ServiceProvider {
  struct Picker: View {
    @Environment(Hub.self) private var hub
    @Environment(\.serviceProviders) private var providers
    
    let path: String
    @Binding var context: Hub.Context
    
    var body: some View {
      if !providers.isEmpty {
        SwiftUI.Picker("Provider", selection: $context.service) {
          Text("Automatic").tag(Optional<String>.none)
          ForEach(providers) { provider in
            Text(provider.label).tag(provider.id)
          }
        }.pickerStyle(.main).task(id: providers) {
          guard let service = context.service else { return }
          guard !providers.contains(where: { $0.id == service }) else { return }
          context.service = nil
        }
      }
    }
  }
  struct Sync: ViewModifier {
    @State private var providers: [ServiceProvider] = []
    let path: String
    
    func body(content: Content) -> some View {
      content.hubStream("hub/api/services", path, to: $providers).environment(\.serviceProviders, providers)
    }
  }
}
struct ServicePickerModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
  }
}
extension EnvironmentValues {
  var serviceContext: Hub.Context? {
    get { self[ServiceContextKey.self] }
    set { self[ServiceContextKey.self] = newValue }
  }
  var serviceProviders: [ServiceProvider] {
    get { self[Providers.self] }
    set { self[Providers.self] = newValue }
  }
  private struct Providers: EnvironmentKey {
    static var defaultValue: [ServiceProvider] { [] }
  }
}
struct ServiceContextKey: EnvironmentKey, PreferenceKey {
  static var defaultValue: Hub.Context? { nil }
  static func reduce(value: inout Hub.Context?, nextValue: () -> Hub.Context?) {}
}
