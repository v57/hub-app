//
//  Support.swift
//  Hub
//
//  Created by Linux on 27.05.26.
//

import SwiftUI

struct SupportView: View {
//  @State private var btc = Copyable(title: "BTC", value: "1AdcE6nUa4xKC2ZsW5FcffQryUH25KuVjK")
//  @State private var trc = Copyable(title: "TRC20", value: "TXaCJRumZUN89pF1DzxmjsLxLsrrzArZ3k")
  var body: some View {
    HomeGrid {
      Link("Discord", destination: URL(string: "https://discord.gg/DqsS4zarJM")!).lineLimit(1)
      Link("GitHub", destination: URL(string: "https://github.com/v57/hub-app")!).lineLimit(1)
/**
 A multi trillion dollar company Apple is not allowing me to put support links
 They require to put `in app purchases` so they can collect 30% of your support money for a poor developer
 As i choose to be born in Russia, i wasn't allowed to receive money from the app store
 So thank you anyway if you find this links and support this project
*/
//      Link("Discord", destination: URL(string: "https://discord.gg/DqsS4zarJM")!).lineLimit(1)
//      Link("Boosty", destination: URL(string: "https://boosty.to/v57hub/donate")!).lineLimit(1)
//      Link("GitHub", destination: URL(string: "https://github.com/sponsors/v57")!).lineLimit(1)
//      Link("Buy Me\na Coffee", destination: URL(string: "https://buymeacoffee.com/v57hub")!).lineLimit(2)
//      Link("Ko-Fi", destination: URL(string: "https://ko-fi.com/v57hub")!).lineLimit(1)
//      Link("Patreon", destination: URL(string: "https://patreon.com/v57hub")!).lineLimit(1)
//      AsyncButton(btc.displayedTitle) {
//        try await copyBtc()
//      }.lineLimit(1).contentTransition(.numericText()).animation(.smooth, value: btc.copied)
//      AsyncButton(trc.displayedTitle) {
//        try await copyTrc()
//      }.lineLimit(1).contentTransition(.numericText()).animation(.smooth, value: trc.copied)
    }.buttonStyle(LinkButtonStyle())
  }
//  func copyTrc() async throws {
//    trc.copied = true
//    trc.value.copyToClipboard()
//    try await Task.sleep(for: .seconds(3))
//    trc.copied = false
//  }
//  func copyBtc() async throws {
//    btc.copied = true
//    btc.value.copyToClipboard()
//    try await Task.sleep(for: .seconds(3))
//    btc.copied = false
//  }
//  struct Copyable {
//    let title: LocalizedStringKey
//    let value: String
//    var displayedTitle: LocalizedStringKey { copied ? "Copied" : title }
//    var copied = false
//  }
  struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.multilineTextAlignment(.center)
        .body()
        .minimumScaleFactor(0.6)
        .blockBackground()
        .environment(\.isPressed, configuration.isPressed)
        .animation(.smooth(duration: 0.25), value: configuration.isPressed)
    }
  }
}

#Preview {
  SupportView().test()
}
