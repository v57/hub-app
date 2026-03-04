//
//  Styles.swift
//  Hub
//
//  Created by Dmitry Kozlov on 12/6/25.
//

import SwiftUI

extension View {
  func badgeStyle() -> some View {
    font(.caption2).foregroundStyle(.white)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(.red, in: .capsule)
  }
  @ViewBuilder
  func glassProminentButton() -> some View {
    #if os(visionOS)
    buttonStyle(.borderedProminent)
    #else
    if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
      buttonStyle(.glassProminent)
    } else {
      buttonStyle(.borderedProminent)
    }
    #endif
  }
  func modifier<Content: View>(@ViewBuilder _ modifiy: (Self) -> Content) -> Content {
    modifiy(self)
  }
}

struct ActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    let up = configuration.isPressed
    configuration.label.body()
      .foregroundStyle(.red)
      .padding(.horizontal, 12).padding(.vertical, 4)
      .frame(minWidth: 60)
      .background(.black.opacity(0.001))
      .background(.red.opacity(0.1), in: .capsule)
      .scaleEffect(up ? 1.1 : 1.0)
      .animation(.spring(response: up ? 0.1 : 0.5, dampingFraction: up ? 1.0 : 0.5), value: up)
      .contentTransition(.numericText())
  }
}
struct TabButtonStyle: ButtonStyle {
  let selected: Bool
  func makeBody(configuration: Configuration) -> some View {
    let up = configuration.isPressed
    configuration.label.note()
      .foregroundStyle(.red)
      .labelStyle(LabelStyle())
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(.black.opacity(0.001))
      .background(.red.opacity(selected ? 0.1 : 0), in: .capsule)
      .scaleEffect(up ? 1.1 : 1.0)
      .animation(.spring(response: up ? 0.1 : 0.5, dampingFraction: up ? 1.0 : 0.5), value: up)
      .contentTransition(.numericText())
  }
  struct LabelStyle: SwiftUI.LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
      HStack(spacing: 4) {
        configuration.icon.frame(height: 0)
        configuration.title
      }
    }
  }
}
struct Background: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> Color {
    Color.main(dark: environment.colorScheme == .dark)
  }
  struct Screen: View {
    @Environment(\.colorScheme) var colorScheme
    var body: some View {
      Color.main(dark: colorScheme == .dark).ignoresSafeArea()
    }
  }
}

extension Color {
  static func main(dark: Bool) -> Color {
    if dark {
      Color(hue: 0.091, saturation: 0.186, brightness: 0.156)
    } else {
      Color.white
    }
  }
}

extension Text {
  func largeTitle() -> Text {
    font(.system(size: 20, weight: .semibold, design: .rounded))
  }
  func title() -> Text {
    font(.system(size: 16, weight: .medium, design: .rounded))
  }
  func code() -> Text {
    font(.system(size: 12, weight: .medium))
      .fontDesign(.monospaced)
      .foregroundStyle(.secondary)
  }
  func body() -> Text {
    font(.system(size: 14, weight: .medium, design: .rounded))
  }
  func note() -> Text {
    font(.system(size: 12, weight: .medium, design: .rounded))
  }
  func secondary() -> Text {
    note().foregroundStyle(.secondary)
  }
  func error() -> Text {
    note().foregroundStyle(.red)
  }
  func app() -> Text {
    font(.system(size: 10, design: .rounded))
  }
}
extension View {
  func page() -> some View {
    body().fontDesign(.rounded)
      .background(Background.Screen())
  }
  func test() -> some View {
    NavigationStack {
      environment(Hub.test).page()
    }.frame(minHeight: 600)
  }
  func title() -> some View {
    font(.system(size: 16, weight: .medium, design: .rounded))
  }
  func body() -> some View {
    font(.system(size: 14, weight: .medium, design: .rounded))
  }
  func note() -> some View {
    font(.system(size: 12, weight: .medium, design: .rounded))
  }
  func secondary() -> some View {
    note().foregroundStyle(.secondary)
  }
  func error() -> some View {
    note().foregroundStyle(.red)
  }
  func icon() -> some View {
    font(.system(size: 32, weight: .semibold, design: .rounded))
  }
}

#Preview {
  VStack {
    Image(systemName: "tree").icon()
    Text("Title").title()
    Text("Body").body()
    Text("Note").note()
    Text("Secondary").secondary()
    Text("Error Message").error()
    Button("Action", systemImage: "hammer") { }
      .buttonStyle(TabButtonStyle(selected: false))
    Button("Action", systemImage: "hammer") { }
      .buttonStyle(TabButtonStyle(selected: true))
  }.frame(maxWidth: .infinity, maxHeight: .infinity).test()
}
