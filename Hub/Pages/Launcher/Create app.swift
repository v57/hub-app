//
//  Create app.swift
//  Hub
//
//  Created by Dmitry Kozlov on 22/2/25.
//

import SwiftUI

struct CreateApp: View {
  typealias Create = Hub.Launcher.Create
  typealias Setup = Hub.Launcher.Setup
  enum AppType {
    case bun, shell
  }
  @Environment(Hub.self) var hub
  @Environment(\.dismiss) var dismiss
  @State var install: String = ""
  @State var uninstall: String = ""
  @State var directory: String = ""
  @State var launch: String = ""
  @State var type: AppType = .shell
  @State var repo: String = ""
  @State var restarts: Bool = true
  @State var name: String = ""
  var defaultName: String? {
    switch type {
    case .bun:
      let components = repo.components(separatedBy: "/")
      if components.count > 1, !components[1].isEmpty {
        return components[1]
      }
    case .shell:
      if !launch.isEmpty {
        return launch.components(separatedBy: " ").first
      }
    }
    return nil
  }
  var isReady: Bool { defaultName != nil }
  var body: some View {
    VStack(alignment: .leading) {
      Picker("Type", selection: $type) {
        Text("Shell").tag(AppType.shell)
        Text("Bun").tag(AppType.bun)
      }.pickerStyle(.main)
      TextField(defaultName ?? "App Name", text: $name)
        .fontDesign(.monospaced)
      switch type {
      case .bun:
        TextField("GitHub Repo", text: $repo)
      case .shell:
        VStack {
          TextField("Install script", text: $install, axis: .vertical)
            .lineLimit(3...100)
          TextField("Uninstall script", text: $uninstall, axis: .vertical)
            .lineLimit(3...100)
          TextField("Launch directory", text: $directory)
          TextField("Launch command", text: $launch)
        }.fontDesign(.monospaced).keyboard(style: .code)
      }
      Toggle("Restart on crash", isOn: $restarts)
    }.frame(maxHeight: .infinity, alignment: .top)
      .toolbar {
        HStack {
          Button("Cancel", role: .cancel) {
            dismiss()
          }
          if isReady {
            Button("Create") {
              guard let create else { return }
              Task { try await hub.launcher.create(create) }
              dismiss()
            }.buttonStyle(.borderedProminent).transition(.blurReplace)
          }
        }.animation(.smooth, value: isReady)
      }
  }
  var create: Create? {
    guard let defaultName else { return nil }
    return Create(name: name.replacingEmpty(with: defaultName), active: true, restarts: restarts, setup: setup)
  }
  var setup: Setup {
    switch type {
    case .bun: .bun(.init(repo: repo, commit: nil, command: nil))
    case .shell: .sh(.init(directory: directory.isEmpty ? nil : directory, install: install.commands(), uninstall: uninstall.commands(), run: launch))
    }
  }
}
extension String {
  func replacingEmpty(with value: String) -> String {
    isEmpty ? value : self
  }
  func commands() -> [String]? {
    isEmpty ? nil : components(separatedBy: "\n")
  }
}

#Preview {
  CreateApp().padding().test()
}
