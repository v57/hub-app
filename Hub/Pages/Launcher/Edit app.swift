//
//  Edit app.swift
//  Hub
//
//  Created by Linux on 12.07.25.
//

import SwiftUI

struct EditApp: View {
  let app: Hub.Launcher.AppInfo
  @Environment(\.dismiss) var dismiss
  @Environment(Hub.self) var hub
  @State var env: [Env] = [
    Env(),
  ]
  @State var secrets: [Env] = [
    Env(),
  ]
  var body: some View {
    List {
      Section("Environment values") {
        ForEach($env) { $env in
          EnvView(env: $env)
        }
      }
      Section("Secret keys") {
        ForEach($secrets) { $secret in
          SecretView(env: $secret)
        }
      }
    }.toolbar {
      Button("Cancel", role: .cancel) {
        dismiss()
      }
      if hasChanges {
        AsyncButton("Save") {
          try await save()
          dismiss()
        }.buttonStyle(.borderedProminent)
      }
    }.task(id: env) {
      if !env.contains(where: { $0.isEmpty }) {
        env.append(.init())
      }
    }.task(id: secrets) {
      if !secrets.contains(where: { $0.isEmpty }) {
        secrets.append(.init())
      }
    }.navigationTitle(app.name).task(id: app.settings) {
      if let env = app.settings?.env {
        self.env = env.map { key, value in
          Env(key: key, value: value)
        }
      }
    }
  }
  func save() async throws {
    struct UpdateSettings: Encodable {
      let app: String
      let settings: Hub.Launcher.AppSettings
    }
    if let settings {
      try await hub.launcher.app(id: app.name).updateSettings(settings)
    }
  }
  var hasChanges: Bool { settings != nil }
  var settings: Hub.Launcher.AppSettings? {
    var env = [String: String]()
    self.env.forEach { e in
      guard !e.key.isEmpty && !e.value.isEmpty else { return }
      env[e.key] = e.value
    }
    let envChanged = env != (app.settings?.env ?? [:])
    var secrets = [String: String]()
    self.env.forEach { e in
      guard !e.key.isEmpty && !e.value.isEmpty else { return }
      secrets[e.key] = e.value
    }
    let oldValue = app.settings ?? Hub.Launcher.AppSettings(env: nil, secrets: nil)
    let settings = Hub.Launcher.AppSettings(env: envChanged ? env : nil, secrets: secrets.isEmpty ? nil : secrets)
    guard oldValue != settings else { return nil }
    return settings
  }
  struct EnvView: View {
    @Binding var env: Env
    var body: some View {
      HStack {
        TextField("Key", text: $env.key)
          .frame(width: 80)
        TextField("Value", text: $env.value)
      }.keyboard(style: .code)
    }
  }
  struct SecretView: View {
    @Binding var env: Env
    var body: some View {
      HStack {
        SecureField("Key", text: $env.key)
          .frame(width: 80)
        SecureField("Value", text: $env.value)
      }
    }
  }
  struct Env: Identifiable, Hashable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
    var placeholder: String?
    var isEmpty: Bool { key.isEmpty && value.isEmpty }
  }
}

struct TestEditApp: View {
  @State var apps: Hub.Launcher.Apps?
  var body: some View {
    ZStack {
      if let app = apps?.apps.last {
        EditApp(app: app)
      } else {
        Text("Loading")
      }
    }.hubStream("launcher/info", to: $apps)
  }
}

#Preview {
  TestEditApp().test()
}

