//
//  PageLayout.swift
//  Hub
//
//  Pieces every hub page shares: the main area beside an inspector, the Grid | List switch, a card's selection ring,
//  a labeled bar, and the empty and loading states.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

/// The page's main area and, beside it, the selected thing's inspector. On iPhone there's no room beside it: the
/// page pushes the inspector instead.
struct PageWithInspector<Main: View, Inspector: View>: View {
  var name: String
  var showsInspector = true
  @ViewBuilder var main: Main
  @ViewBuilder var inspector: Inspector
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom == .phone || !showsInspector {
      main.kitPane(.content)
    } else {
      ResizableSplit(
        "hub.\(name).inspector", pane: .trailing, width: idiom.isTouch ? 340 : 320, range: 280...460, mainMinWidth: 420
      ) {
        main.kitPane(.content)
      } pane: {
        KitInspector(width: nil) { inspector }
      }
    }
  }
}

/// How a page lists its things: cards in a grid, or rows in a table
enum ListStyle: String, CaseIterable, Hashable {
  case grid, list
  var title: String { self == .grid ? "Grid" : "List" }
  var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

/// The toolbar's Grid | List switch, kept per page
struct ListStyleSwitch: View {
  @Binding var style: ListStyle
  var body: some View {
    KitSegmented(selection: $style, segments: ListStyle.allCases.map {
      KitSegment($0.title, value: $0, systemImage: $0.systemImage)
    })
    .environment(\.kitToolbarIconOnly, true)
  }
}

/// A card in a page's grid: raised, with the accent ring while selected
struct GridCard<Content: View>: View {
  var isSelected = false
  var action: (() -> Void)?
  @ViewBuilder var content: Content

  var body: some View {
    let card = content
      .padding(KitMetrics.cardPadding)
      .padding(.bottom, 4)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .kitSurface(.card)
      .overlay {
        if isSelected {
          RoundedRectangle(cornerRadius: KitMetrics.radiusCard).strokeBorder(Hue.accent.fill, lineWidth: 1.5)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: KitMetrics.radiusCard))
    if let action {
      Button(action: action) { card }.buttonStyle(.plain)
    } else {
      card
    }
  }
}

/// A labeled bar: "CPU ▬▬▬── 34%"
struct LabeledBar: View {
  let label: String
  let value: Double?
  var hue: Hue = .blue
  var text: String?

  var body: some View {
    HStack(spacing: 8) {
      Text(label).kitFont(.caption).frame(width: 52, alignment: .leading)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(.kitFill)
          if let value {
            Capsule().fill(hue.fill).frame(width: max(4, proxy.size.width * min(max(value, 0), 1)))
          }
        }
      }
      .frame(height: 4)
      Text(text ?? value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
        .kitFont(.caption).foregroundStyle(.kitLabel).monospacedDigit()
        .frame(width: 52, alignment: .trailing)
    }
    .animation(.kit, value: value)
  }
}

/// A key and its value in a card: "Hub Network   10.57.0.2"
struct KeyValueLine: View {
  let key: String
  let value: String
  var mono = false
  var body: some View {
    HStack {
      Text(key).kitFont(.caption)
      Spacer(minLength: 8)
      Text(value).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11)).foregroundStyle(.kitLabel)
        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }
  }
}

/// Grid, list or nothing yet: a page's first load draws quiet placeholder cards, then its content
struct LoadingCards: View {
  var count = 3
  var body: some View {
    VStack(spacing: KitMetrics.gutter) {
      ForEach(0..<count, id: \.self) { _ in
        HStack(spacing: 10) {
          RoundedRectangle(cornerRadius: 6).fill(.kitFill).frame(width: 28, height: 28)
          VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(.kitFill).frame(width: 140, height: 8)
            Capsule().fill(.kitFillSoft).frame(width: 90, height: 6)
          }
          Spacer()
        }
        .padding(12)
        .kitSurface(.card)
      }
    }
  }
}
#endif
