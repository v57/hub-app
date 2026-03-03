//
//  Install Hub.swift
//  Hub
//
//  Created by Linux on 03.11.25.
//

import SwiftUI

struct InstallationGuide: View {
  enum OS {
    case macOS, iOS, docker, windows
    var title: String {
      switch self {
      case .macOS: "macOS / Linux"
      case .iOS: "iOS / tvOS"
      case .docker: "Docker"
      case .windows: "Windows"
      }
    }
  }
  @State var os: OS = .macOS
  var body: some View {
    VStack {
      Group {
        switch os {
        case .macOS:
          Text("Install [Bun](https://bun.com)").title()
          CodeView("curl -fsSL https://bun.sh/install | bash")
          Text("Run").title()
          CodeView("bunx v57/hub")
        case .docker:
          Text("Run").title()
          CodeView("""
            docker pull v57dev/hub
            docker run -d -p 1997:1997 --name Hub v57dev/hub
            """)
          Text("Docker allows to run Hub server on a virtual machine.\nAvailable for macOS, Linux and Windows")
            .secondary()
        case .iOS:
          Text("""
          Currently you can only start hub server on
          **macOS**, **Linux**, **Windows** and using **Docker**.
          In the future **any Hub App** may be used to connect your services
          """).secondary()
        case .windows:
          Text("Install [Bun](https://bun.com)").title()
          CodeView(title: "Powershell", #"powershell -c "irm bun.sh/install.ps1 | iex""#)
          Text("Run").title()
          CodeView(title: "Powershell", "bunx v57/hub")
        }
      }.transition(.blurReplace)
    }.multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
      .safeAreaInset(edge: .bottom) {
        HStack(spacing: 4) {
          button(os: .macOS)
          button(os: .docker)
          button(os: .iOS)
          button(os: .windows)
        }.lineLimit(1).padding(.bottom, 4)
      }
      .safeAreaPadding(.horizontal)
      .contentTransition(.numericText())
      .navigationTitle("Installation Guide")
      .toolbarTitleDisplayMode(.inline)
  }
  func button(os: OS) -> some View {
    Button {
      withAnimation { self.os = os }
    } label: {
      Text(os.title)
    }.buttonStyle(TabButtonStyle(selected: self.os == os))
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
        AsyncButton {
          try await copy()
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            header
            codeView
          }.padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
      }.shadow(color: .black.opacity(0.2), radius: 10)
        .multilineTextAlignment(.leading)
    }
    var codeView: some View {
      Text(code).code().textSelection()
    }
    var header: some View {
      HStack(spacing: 4) {
        Image(systemName: copied ? "checkmark.circle.fill" : "apple.terminal.fill")
        Text(copied ? "Copied to clipboard" : title)
      }.font(.caption2).foregroundStyle(.red.opacity(0.7))
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
