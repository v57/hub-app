//
//  Translate.swift
//  Hub
//
//  Created by Linux on 05.10.25.
//

#if os(macOS) || os(iOS)
import SwiftUI
import Translation

@available(macOS 15.0, iOS 18.0, *)
struct TranslateView: View {
  @State var languages = [String]()
  @State var installed: Set<String>?
  @State var source: String = "en"
  @State var target: String = "de"
  @State var translation = Translation.main
  @State var text: String = ""
  @State var result: String = ""
  @State private var isRefreshing = false
  var body: some View {
    ScrollView {
      VStack {
        Text(result).textSelection().contentTransition(.numericText())
      }.task {
        languages = await LanguageAvailability().supportedLanguages
          .map(\.minimalIdentifier).sorted(by: { $0.languageName < $1.languageName })
      }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }.overlay {
      ZStack {
        if text.isEmpty {
          VStack {
            Image(systemName: "translate").font(.system(size: 88))
              .gradientBlur(radius: 1)
            Text("Translate").font(.title)
            VStack(alignment: .center, spacing: 4) {
              HStack(spacing: 4) {
                Image(systemName: "circle.hexagonpath.fill").frame(width: 16)
                  .foregroundStyle(.red.gradient)
                Text("Use in your Hub").font(.caption2)
              }
              HStack(spacing: 4) {
                Image(systemName: "lock").frame(width: 16)
                Text("No internet needed").font(.caption2)
              }.foregroundStyle(.green)
              HStack(spacing: 4) {
                Image(systemName: "lock").frame(width: 16)
                Text("No translation history").font(.caption2)
              }.foregroundStyle(.green)
              HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle").frame(width: 16)
                Text("Select language and start typing to download it").secondary()
              }
            }.symbolVariant(.fill)
          }.transition(.blurReplace)
        }
      }.animation(.smooth, value: text.isEmpty)
    }.toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task {
          isRefreshing = true
          defer { isRefreshing = false }
          await translation.updateLanguages()
        }
      }.disabled(isRefreshing)
    }.safeAreaInset(edge: .bottom) {
      VStack(alignment: .leading) {
        HStack {
          Picker("Source", selection: $source) {
            ForEach(languages, id: \.self) { language in
              Label(language.languageName, systemImage: icon(status: installed?.contains(language)))
                .symbolVariant(.circle.fill)
                .tag(language)
            }
          }
          Button("Switch", systemImage: "arrow.left.arrow.right") {
            let source = source
            withAnimation {
              self.source = target
              target = source
              text = result
            }
          }.labelStyle(.iconOnly)
          Picker("Target", selection: $target) {
            ForEach(languages, id: \.self) { language in
              Label(language.languageName, systemImage: icon(status: installed?.contains(language)))
                .symbolVariant(.circle.fill).tag(language)
            }
          }
        }
        TextField("Text to translate", text: $text, axis: .vertical)
          .textFieldStyle(.roundedBorder)
      }.padding().task(id: text) {
        do {
          let text = try await translation.translate(text: text, source: source, target: target)
          withAnimation { result = text }
        } catch { }
      }
    }.task {
      installed = await Set(LanguageAvailability().installed().map { $0.minimalIdentifier })
    }.frame(maxWidth: .infinity).modifier(TranslationModifier()).environment(translation)
  }
  func icon(status: Bool?) -> String {
    switch status {
    case false:
      "arrow.down"
    default:
      ""
    }
  }
}

@available(macOS 15.0, iOS 18.0, *)
extension LanguageAvailability {
  struct Pairs {
    var available = Set<LanguagePair>()
    var unavailable = Set<LanguagePair>()
  }
  struct LanguagePair: Hashable, Identifiable {
    var id: String { sourceId + targetId }
    let source: Locale.Language
    let target: Locale.Language
    var sourceId: String { source.minimalIdentifier }
    var targetId: String { target.minimalIdentifier }
  }
  func pairs() async -> Pairs {
    var pairs = Pairs()
    guard !ProcessInfo.isPreviews else { return pairs }
    let languages = await supportedLanguages
    let sendable = LanguageAvailability()
    for i in 0..<languages.count - 1 {
      let source = languages[i]
      for j in (i+1)..<languages.count {
        let target = languages[j]
        let status = await sendable.status(from: source, to: target)
        switch status {
        case .installed:
          pairs.available.insert(LanguagePair(source: source, target: target))
        case .unsupported: break
        case .supported:
          pairs.unavailable.insert(LanguagePair(source: source, target: target))
        @unknown default: break
        }
      }
    }
    return pairs
  }
  func installed() async -> Set<Locale.Language> {
    let languages = await supportedLanguages
    let sendable = LanguageAvailability()
    var operations = 0
    var installed = Set<Locale.Language>()
    for i in 0..<languages.count - 1 {
      let source = languages[i]
      for j in (i+1)..<languages.count {
        let target = languages[j]
        let status = await sendable.status(from: source, to: target)
        operations += 1
        switch status {
        case .installed:
          installed.insert(source)
          installed.insert(target)
        default: break
        }
      }
    }
    return installed
  }
}

extension String {
  var languageName: String {
    Locale.current.localizedString(forIdentifier: self)!
  }
  var language: Locale.Language {
    Locale.Language(identifier: self)
  }
}

@available(macOS 15.0, iOS 18.0, *)
#Preview {
  NavigationStack {
    TranslateView()
  }.environment(Hub.test)
}
#endif
