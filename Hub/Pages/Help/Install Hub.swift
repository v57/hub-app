//
//  Install Hub.swift
//  Hub
//
//  Created by Linux on 03.11.25.
//

import SwiftUI

struct InstallationGuide: View {
  enum OS {
    case macOS, iOS, tvOS, linux, docker, windows
  }
  @State var os: OS = .macOS
  var body: some View {
    ScrollView {
      VStack(alignment: .leading) {
        Picker("OS", selection: $os.animation()) {
          Text("macOS").tag(OS.macOS)
          Text("Linux").tag(OS.linux)
          Text("Docker").tag(OS.docker)
          Text("iOS").tag(OS.iOS)
          Text("tvOS").tag(OS.tvOS)
          Text("Windows").tag(OS.windows)
        }.pickerStyle(.segmented).labelsHidden()
        switch os {
        case .macOS, .linux:
          Text("First you need to install Bun").transition(.blurReplace)
          CodeView("curl -fsSL https://bun.sh/install | bash")
          Text("Now install hub launcher").transition(.blurReplace)
          CodeView("git clone https://github.com/v57/hub-launcher\ncd hub-launcher\nbun install")
          Text("Run").transition(.blurReplace)
          CodeView("bun run .")
        case .docker:
          Text("Docker allows to run Hub server on a virtual machine. Available for macOS, Linux and Windows")
            .transition(.blurReplace)
          CodeView("""
            docker pull v57dev/hub
            docker run -d -p 1997:1997 --name hub-launcher v57dev/hub
            """)
        case .iOS, .tvOS:
          Text("Currently you can only start hub server on **macOS**, **Linux**, **Windows** and using **Docker**.\nIn the future any **Hub** App may be used to connect your services")
            .transition(.blurReplace)
        case .windows:
          Text("Windows version wasn't tested so it's better to use Docker installation.")
            .fontWeight(.medium)
            .transition(.blurReplace)
          Text("1. Install [bun](https://bun.com)")
            .transition(.blurReplace)
          CodeView(#"powershell -c "irm bun.sh/install.ps1 | iex""#)
          Text("2. Download [Hub Lite](http://github.com/v57/hub-lite)")
            .transition(.blurReplace)
          Text("3. Run from hub-lite folder")
            .transition(.blurReplace)
          CodeView("bun install && bun run .")
          
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .safeAreaPadding(.horizontal)
        .contentTransition(.numericText())
    }.navigationTitle("Installation Guide")
  }
  struct CodeView: View {
    let title: LocalizedStringKey
    let code: String
    @State var copied: Bool = false
    init(title: LocalizedStringKey = "Terminal", _ code: String) {
      self.title = title
      self.code = code
    }
    var body: some View {
      HStack {
        Text(code).textSelection()
          .font(.caption)
          .fontDesign(.monospaced)
        Spacer()
        AsyncButton(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark.circle.fill" : "document.on.document.fill") {
          try await copy()
        }.labelStyle(.iconOnly)
          .contentTransition(.symbolEffect)
      }
      .padding().overlay(alignment: .topLeading) {
        Text(title).padding(.leading).padding(.top, 4)
          .font(.caption2)
          .foregroundStyle(.green.opacity(0.7))
      }.foregroundStyle(.green)
        .background(.black, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -14)
        .transition(.blurReplace)
    }
    func copy() async throws {
      code.copyToClipboard()
      withAnimation {
        copied = true
      }
      try await Task.sleep(for: .seconds(1))
      withAnimation {
        copied = false
      }
    }
  }
}

#Preview {
  NavigationStack {
    InstallationGuide()
  }
}
