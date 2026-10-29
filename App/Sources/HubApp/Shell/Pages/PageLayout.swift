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

extension EnvironmentValues {
  /// Pages leave out their title bar: Apple TV's hub tab names the page in its own header
  @Entry var hidesPageToolbar = false
}

extension View {
  /// The page's title bar (the kit's toolbar), unless the page sits under a header of its own (`hidesPageToolbar`)
  func pageToolbar(
    _ title: String, meta: [String] = [], systemImage: String, hue: Hue = .accent, status: WorkStatus = .idle,
    @ToolbarSlotBuilder tools: () -> [ToolbarSlot]
  ) -> some View {
    modifier(PageToolbar(windowTitle: title, title: KitTitle(title, meta: meta, systemImage: systemImage, hue: hue, status: status), tools: tools()))
  }

  /// The page's title bar with any title view
  func pageToolbar<Title: View>(
    _ windowTitle: String, @ViewBuilder title: () -> Title, @ToolbarSlotBuilder tools: () -> [ToolbarSlot]
  ) -> some View {
    modifier(PageToolbar(windowTitle: windowTitle, title: title(), tools: tools()))
  }
}

private struct PageToolbar<Title: View>: ViewModifier {
  let windowTitle: String
  let title: Title
  let tools: [ToolbarSlot]
  @Environment(\.hidesPageToolbar) private var hides

  func body(content: Content) -> some View {
    if hides {
      content
    } else {
      content.kitToolbar(windowTitle, title: { title }) { tools }
    }
  }
}

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
      Text(value).kitFont(mono ? .monoSmall : .caption).foregroundStyle(.kitLabel)
        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }
  }
}

/// A name to type in a kit sheet: New Group, Rename Device
struct NameSheet: View {
  let title: String
  var meta: String?
  let systemImage: String
  var hue: Hue = .accent
  let confirm: String
  @State var name: String
  let action: (String) -> Void
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    KitSheet(title: title, meta: meta, systemImage: systemImage, hue: hue) {
      FormCard {
        FormRow("Name", systemImage: "textformat") {
          TextField("Name", text: $name).kitField().frame(maxWidth: 240)
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button(confirm) {
        action(trimmed)
        dismiss()
      }
      .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
    }
  }
}

/// Views in lines that wrap at the container's width: chips, tokens
struct FlowLayout: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
    return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (frame, subview) in zip(frames(width: bounds.width, subviews: subviews), subviews) {
      subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
    }
  }

  private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
    var frames = [CGRect]()
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        x = 0
        y += line + spacing
        line = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      line = max(line, size.height)
    }
    return frames
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
