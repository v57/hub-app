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
          Placeholder(image: "translate", title: "Translate", description: "by Apple Intelligence") {
            Label("Use in your Hub", systemImage: "circle.hexagonpath.fill")
              .foregroundStyle(.red.gradient, .primary)
            Label("No internet needed", systemImage: "lock.badge.checkmark")
              .foregroundStyle(.green, .primary)
            Label("No translation history", systemImage: "lock.badge.checkmark")
              .foregroundStyle(.green, .primary)
            Label("Select language and start typing to download it", systemImage: "arrow.down.circle")
          }
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
          }.frame(maxWidth: .infinity)
          Button("Switch", systemImage: "arrow.left.arrow.right") {
            let source = source
            withAnimation {
              self.source = target
              target = source
              text = result
            }
          }.labelStyle(.iconOnly).buttonStyle(ActionButtonStyle())
          Picker("Target", selection: $target) {
            ForEach(languages, id: \.self) { language in
              Label(language.languageName, systemImage: icon(status: installed?.contains(language)))
                .symbolVariant(.circle.fill).tag(language)
            }
          }.frame(maxWidth: .infinity)
        }.frame(maxWidth: 400)
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
  TranslateView().test()
}
#endif
