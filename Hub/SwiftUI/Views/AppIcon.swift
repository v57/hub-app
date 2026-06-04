//
//  File.swift
//  Hub
//
//  Created by Linux on 05.03.26.
//

import SwiftUI

extension View {
  func iconBadge(_ value: Int?) -> some View {
    if let value {
      environment(\.badge, Text("\(value)"))
    } else {
      environment(\.badge, nil)
    }
  }
  func iconBadge(_ value: LocalizedStringKey?) -> some View {
    if let value {
      environment(\.badge, Text(value))
    } else {
      environment(\.badge, nil)
    }
  }
  func bottomLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    background {
      let content = content()
      GeometryReader { view in
        content.app().offset(y: view.size.height - 4)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
      }
    }
  }
}

private extension EnvironmentValues {
  private struct Badge: EnvironmentKey {
    static var defaultValue: Text? { nil }
  }
  var badge: Text? {
    get { self[Badge.self] }
    set { self[Badge.self] = newValue }
  }
}

private struct AppIcon<Title: View, Icon: View>: View {
  @Environment(\.badge) private var badge
  let title: Title
  let icon: Icon
  var hasBadge: Bool { badge != nil }
  var body: some View {
    icon.gradientBlur(radius: hasBadge ? 4 : 1)
      .contentTransition(.symbolEffect).icon()
      .blockBackground().overlay(alignment: .top) {
        if let badge {
          badge.foregroundStyle(.white).app().padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint, in: .capsule)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, -2)
            .offset(y: -2)
            .transition(.blurReplace)
        }
      }.bottomLabel {
        title
      }
  }
}

extension LabelStyle where Self == AppIconLabelStyle {
  static var appIcon: Self { Self() }
}

struct AppIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    AppIcon(title: configuration.title, icon: configuration.icon)
  }
}

extension AppIcon where Title == Text, Icon == Image {
  init(title: LocalizedStringKey, systemImage: String) {
    self.title = Text(title)
    self.icon = Image(systemName: systemImage)
  }
}
extension AppIcon where Title == Text, Icon == Text {
  init(title: String, textIcon: String) {
    self.title = Text(title)
    self.icon = Text(textIcon)
  }
}
