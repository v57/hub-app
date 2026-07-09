//
//  Translate.swift
//  Hub
//
//  Created by Linux on 05.10.25.
//

#if os(macOS) || os(iOS)
#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
@preconcurrency import Translation

@available(macOS 15.0, iOS 18.0, *)
struct TranslateView: View {
  @State var languages = [String]()
  @State var installed: Set<String>?
  @State var task = TranslationTask(text: "", source: "en", target: "de")
  @State var translation = Translation.main
  @State var result: String = ""
  @State private var isRefreshing = false
  @State var translating: Bool = false
  var body: some View {
    GeometryReader { view in
      ScrollView {
        Text(result).foregroundStyle(.primary.opacity(translating ? 0.8 : 1))
          .textSelection().contentTransition(.numericText())
          .animation(.smooth(duration: 0.4), value: translating)
          .task {
            languages = await LanguageAvailability().supportedLanguages
              .map(\.minimalIdentifier).sorted(by: { $0.languageName < $1.languageName })
          }.frame(maxWidth: .infinity, minHeight: view.size.height, alignment: .bottomLeading).padding()
      }
    }.overlay {
      ZStack {
        if task.text.isEmpty {
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
      }.animation(.smooth, value: task.text.isEmpty)
    }.toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task {
          isRefreshing = true
          defer { isRefreshing = false }
          await translation.updateLanguages()
        }
      }.disabled(isRefreshing)
    }.safeAreaInset(edge: .bottom) {
      VStack(alignment: .center, spacing: 16) {
        HStack {
          Menu {
            ForEach(languages, id: \.self) { language in
              Button(language.languageName, systemImage: icon(status: installed?.contains(language))) {
                task.source = language
              }
            }
          } label: {
            Label(task.source.languageName, systemImage: icon(status: installed?.contains(task.source))).frame(maxWidth: 400)
          }.symbolVariant(.circle.fill)
          Button("Switch", systemImage: "arrow.left.arrow.right") {
            let source = task.source
            withAnimation {
              task.source = task.target
              task.target = source
              task.text = result
            }
          }.labelStyle(.iconOnly)
          Menu {
            ForEach(languages, id: \.self) { language in
              Button(language.languageName, systemImage: icon(status: installed?.contains(language))) {
                task.target = language
              }
            }
          } label: {
            Label(task.target.languageName, systemImage: icon(status: installed?.contains(task.target))).frame(maxWidth: 400)
          }.symbolVariant(.circle.fill)
        }.buttonStyle(ActionButtonStyle()).lineLimit(1)
#if os(visionOS)
        TextField("Text to translate", text: $task.text, axis: .vertical)
          .padding(.horizontal).padding(.vertical, 6)
#else
        if #available(macOS 26.0, iOS 26.0, *) {
          TextField("Text to translate", text: $task.text, axis: .vertical)
            .padding(.horizontal).padding(.vertical, 6)
            .textFieldStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        } else {
          TextField("Text to translate", text: $task.text, axis: .vertical)
            .padding(.horizontal).padding(.vertical, 6)
            .textFieldStyle(.plain)
        }
#endif
      }.padding().task(id: task) { translate() }
    }.task {
      installed = await Set(LanguageAvailability().installed().map { $0.minimalIdentifier })
    }.frame(maxWidth: .infinity).environment(translation)
  }
  func translate() {
    var task = task
    guard !translating else { return }
    Task {
      translating = true
      defer { translating = false }
      while true {
        try await translate(task: task)
        guard self.task != task else { return }
        task = self.task
      }
    }
  }
  func translate(task: TranslationTask) async throws {
    let text = try await translation.translate(text: task.text, source: task.source, target: task.target)
    withAnimation { result = text }
  }
  struct TranslationTask: Hashable {
    var text: String
    var source: String
    var target: String
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
  struct Pairs: Sendable, Hashable {
    var available = Set<LanguagePair>()
    var unavailable = Set<LanguagePair>()
  }
  func pairs() async -> Pairs {
    var pairs = Pairs()
    guard !ProcessInfo.isPreviews else { return pairs }
    let languages = await supportedLanguages
    let sendable: LanguageAvailability
    if #available(iOS 26.4, *), #available(macOS 26.4, *) {
      sendable = LanguageAvailability(preferredStrategy: .lowLatency)
    } else {
      sendable = LanguageAvailability()
    }
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
struct LanguagePair: Hashable, Identifiable, Sendable {
  var id: String { sourceId + targetId }
  let source: Locale.Language
  let target: Locale.Language
  var sourceId: String { source.minimalIdentifier }
  var targetId: String { target.minimalIdentifier }
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
