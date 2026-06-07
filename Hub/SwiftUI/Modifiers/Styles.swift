//
//  Styles.swift
//  Hub
//
//  Created by Dmitry Kozlov on 12/6/25.
//

import SwiftUI
import HubUI

extension View {
  func badgeStyle() -> some View {
    note().foregroundStyle(.red)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(.red.opacity(0.2), in: .capsule)
  }
  func glassStyle<S: InsettableShape>(in shape: S) -> some View {
    self.background {
      shape.fill(.secondaryBackground).strokeBorder(.border)
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
    }
  }
  func modifier<Content: View>(@ViewBuilder _ modifiy: (Self) -> Content) -> Content {
    modifiy(self)
  }
}

struct ActionButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var isFocused: Bool
  var focus: Double { isFocused ? 0.2 : 0.0 }
  func makeBody(configuration: Configuration) -> some View {
    let up = configuration.isPressed
    configuration.label.body()
      .foregroundStyle(.red)
      .padding(.horizontal, 12).padding(.vertical, 4)
      .frame(minWidth: 60)
      .background(.black.opacity(0.001))
      .background(.red.opacity(0.1 + focus), in: .capsule)
      .scaleEffect((up ? 1.1 : 1.0) + focus)
      .animation(.spring(response: up ? 0.1 : 0.5, dampingFraction: up ? 1.0 : 0.5), value: up)
      .animation(.spring, value: isFocused)
      .contentTransition(.numericText())
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
  func app() -> some View {
    font(.system(size: 10, design: .rounded))
  }
}

struct SecondaryBackground: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> Color {
    let isDark = environment.colorScheme == .dark
    if isDark {
#if os(macOS)
      return Color(red: 0.109, green: 0.111, blue: 0.144)
#else
      return Color(red: 0.082, green: 0.082, blue: 0.082)
#endif
    } else {
      return Color(red: 0.98, green: 0.98, blue: 0.98)
    }
  }
}

extension ShapeStyle where Self == SecondaryBackground {
  static var secondaryBackground: Self { SecondaryBackground() }
}

extension ShapeStyle where Self == BorderStyle {
  static var border: BorderStyle {
    BorderStyle()
  }
}

struct BorderStyle: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> LinearGradient {
    let isDark = environment.colorScheme == .dark
    return LinearGradient(colors: [
      primaryColor(dark: isDark),
      SecondaryBackground().resolve(in: environment),
      primaryColor(dark: isDark),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)
  }
  func primaryColor(dark: Bool) -> Color {
    if dark {
      Color(red: 0.271, green: 0.279, blue: 0.369)
    } else {
      Color.white
    }
  }
}

extension ShapeStyle where Self == Color {
  static var tertiaryBackground: Color {
#if os(macOS) || os(iOS)
    Color(.tertiarySystemFill)
#else
    Color.gray.opacity(0.4)
#endif
  }
}

extension Color {
  static var tertiaryBackground: Color {
#if os(macOS) || os(iOS)
    Color(.tertiarySystemFill)
#else
    Color.gray.opacity(0.4)
#endif
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
