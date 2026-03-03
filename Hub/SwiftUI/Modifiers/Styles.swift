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
    configuration.label.foregroundStyle(.blue)
      .fontWeight(.medium)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .frame(minWidth: 60)
      .background(.blue.opacity(0.15), in: .capsule)
  }
}
struct DownloadButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(.blue)
      .fontWeight(.medium)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .frame(minWidth: 60)
      .background(.blue.opacity(0.15), in: .capsule)
  }
}
struct TabButtonStyle: ButtonStyle {
  let selected: Bool
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .medium, design: .rounded))
      .foregroundStyle(.red)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(.red.opacity(selected ? 0.1 : 0), in: .capsule)
  }
}

extension Text {
  func title() -> Text {
    font(.system(size: 16, weight: .medium, design: .rounded))
  }
  func code() -> Text {
    font(.system(size: 12, weight: .medium, design: .monospaced))
      .foregroundStyle(.secondary)
  }
  func body() -> Text {
    font(.system(size: 14, weight: .medium, design: .rounded))
  }
  func note() -> Text {
    font(.system(size: 12, weight: .medium, design: .rounded))
      .foregroundStyle(.secondary)
  }
  func secondary() -> Text {
    note()
  }
  func error() -> Text {
    font(.system(size: 12, weight: .medium, design: .rounded))
      .foregroundStyle(.red)
  }
}
extension View {
  func page() -> some View {
    body()
  }
  func title() -> some View {
    font(.system(size: 16, weight: .medium, design: .rounded))
  }
  func body() -> some View {
    font(.system(size: 14, weight: .medium, design: .rounded))
  }
  func note() -> some View {
    font(.system(size: 12, weight: .medium, design: .rounded))
      .foregroundStyle(.secondary)
  }
  func secondary() -> some View {
    note()
  }
  func error() -> some View {
    font(.system(size: 12, weight: .medium, design: .rounded))
      .foregroundStyle(.red)
  }
}

#Preview {
  VStack {
    Text("Title").title()
    Text("Body").body()
    Text("Note").note()
    Text("Error Message").error()
  }.frame(maxWidth: .infinity, maxHeight: .infinity)
}
