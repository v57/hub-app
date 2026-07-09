//
//  IconView.swift
//  Hub
//
//  Created by Dmitry Kozlov on 6/7/25.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
import HubService

extension Icon {
  @MainActor func body(dark: Bool) -> some View {
    ZStack {
      if let symbol {
        symbol.body(dark: dark)
      } else if let text {
        text.body(dark: dark)
      }
    }.aspectRatio(1, contentMode: .fit)
  }
}

extension Icon.Symbol {
  @MainActor fileprivate func body(dark: Bool) -> some View {
    GeometryReader { view in
      if let color = colors?.background(dark: dark)?.color {
        Color.white
        RadialGradient(colors: [color.opacity(0.6), color], center: .topTrailing, startRadius: 0, endRadius: view.size.height)
      } else {
        Color.gray.opacity(0.2)
      }
      Image(systemName: name)
        .font(.system(size: view.size.height * 0.4, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

extension Icon.Text {
  @MainActor fileprivate func body(dark: Bool) -> some View {
    GeometryReader { view in
      if let color = colors?.background(dark: dark)?.color {
        Color.white
        RadialGradient(colors: [color, color.opacity(0.6)], center: .bottomLeading, startRadius: 0, endRadius: view.size.height * 2)
      } else {
        Color.gray.opacity(0.2)
      }
      Text(name)
        .font(.system(size: view.size.height * 0.4, weight: .bold, design: .rounded))
        .foregroundStyle(colors?.foreground(dark: dark)?.color ?? .primary)
        .minimumScaleFactor(0.01)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct IconView: View {
  let icon: Icon
  var cornerRadius: CGFloat = 12
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    icon.body(dark: colorScheme == .dark)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius * interfaceScale))
  }
}


extension String {
  var color: Color? {
    Color(hex: self)
  }
}

extension Color {
  init?(hex: String) {
    guard let int = Int(hex, radix: 16) else { return nil }
    let red = (int >> 0xf) & 0xff
    let green = (int >> 0x8) & 0xff
    let blue = int & 0xff
    self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
  }
}

#Preview {
  HStack {
    IconView(icon: Icon(symbol: .init(name: "apple.intelligence")))
    IconView(icon: Icon(text: .init(name: "R", colors: Icon.Colors(foreground: "ffffff", background: "ff0000"))))
    IconView(icon: Icon(text: .init(name: "G", colors: Icon.Colors(foreground: "00ff00", background: "000000"))))
    IconView(icon: Icon(text: .init(name: "B", colors: Icon.Colors(foreground: "0000dd", foregroundDark: "aaaaff"))))
    IconView(icon: Icon(text: .init(name: "W", colors: Icon.Colors(foreground: "ffffff"))))
  }.frame(height: 44).padding()
}
