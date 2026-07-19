//
//  Placeholder.swift
//  Hub
//
//  Created by Linux on 04.03.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

struct Placeholder<Content: View>: View {
  let image: String
  let title: LocalizedStringKey
  var description: LocalizedStringKey?
  var isEnabled: Bool?
  @ViewBuilder var content: Content
  var body: some View {
    VStack(spacing: 16) {
      VStack {
        Image(systemName: image).font(.system(size: 88))
          .gradientBlur(radius: isEnabled == true ? 8 : isEnabled == false ? 1 : 4)
          .scaleEffect(isEnabled == false ? 0.8 : 1)
          .frame(width: 120, height: 120)
        VStack(spacing: 4) {
          Text(title).largeTitle()
          if let description {
            Text(description).secondary().multilineTextAlignment(.center)
          }
        }
      }
      VStack(alignment: .center, spacing: 4) {
        content
      }.labelStyle(ItemLabelStyle()).symbolVariant(.fill).note()
    }.frame(maxWidth: .infinity).transition(.blurReplace)
  }
  struct ItemLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
      HStack(spacing: 4) {
        configuration.icon.body()
        configuration.title.foregroundStyle(.secondary)
      }
    }
  }
}
