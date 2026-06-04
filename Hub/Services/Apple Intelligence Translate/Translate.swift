//
//  Translate.swift
//  Hub
//
//  Created by Linux on 29.10.25.
//

import SwiftUI

#if os(macOS) || os(iOS)
@preconcurrency import Translation
@available(macOS 15.0, iOS 18.0, *)
@Observable
@MainActor
class Translation {
  static let main = Translation()
  var processes: [LanguageProcess] = []
  func process(languages: LanguagePair) -> LanguageProcess {
    if let process = processes.first(where: { $0.languages == languages }) {
      return process
    } else {
      let process = LanguageProcess(languages: languages)
      processes.append(process)
      return process
    }
  }
  func cleanup() {
    processes.removeAll(where: { $0.isEmpty })
  }
  
  @ObservationIgnored
  @Published var pairs: LanguageAvailability.Pairs?
  
  private init() {
    Task { await updateLanguages() }
  }
  func translate(text: String, source: String, target: String) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }
    let languages = LanguagePair(source: source.language, target: target.language)
    let process = process(languages: languages)
    let id = UUID()
    if let session = process.session {
      return try await process.translate(session: session, text: text)
    } else {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          let task = TranslationTask(id: id, text: text) { result in
            continuation.resume(with: result)
          }
          process.tasks.append(task)
        }
      } onCancel: {
        Task { @MainActor in
          process.cancelled(id)
        }
      }
    }
  }
  func updateLanguages() async {
    pairs = await LanguageAvailability().pairs()
  }
  @MainActor
  class LanguageProcess {
    let languages: LanguagePair
    var isEmpty: Bool {
      translating == 0 && tasks.isEmpty
    }
    var configuration: TranslationSession.Configuration {
      TranslationSession.Configuration(source: languages.source, target: languages.target)
    }
    var session: TranslationSession?
    var tasks: [TranslationTask] = []
    var translating = 0
    init(languages: LanguagePair) {
      self.languages = languages
    }
    func translate(session: TranslationSession, text: String) async throws -> String {
      try await translate {
        try await session.translate(text).targetText
      }
    }
    func run(session: TranslationSession) async throws {
      self.session = session
      try await translate {
        while !tasks.isEmpty {
          let task = tasks[0]
          do {
            let result = try await session.translate(task.text).targetText
            guard !Task.isCancelled else { continue }
            guard tasks.first?.id == task.id else { continue }
            task.completion(.success(result))
          } catch {
            guard tasks.first?.id == task.id else { continue }
            task.completion(.failure(error))
          }
          tasks.removeFirst()
        }
      }
    }
    func translate<T>(_ action: () async throws -> T) async throws -> T {
      translating += 1
      defer {
        translating -= 1
        if isEmpty {
          Translation.main.cleanup()
        }
      }
      return try await action()
    }
    func cancelled(_ id: UUID) {
      if let index = tasks.firstIndex(where: { $0.id == id }) {
        tasks[index].completion(.failure(CancellationError()))
        tasks.remove(at: index)
      }
    }
  }
  struct TranslationTask {
    let id: UUID
    let text: String
    let completion: (Result<String, Error>) -> Void
  }
}

struct TranslationModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, iOS 18.0, *) {
      let process = Translation.main.processes[safe: 0]
      content.translationTask(process?.configuration) { session in
        print("Switching language to \(session.targetLanguage!.minimalIdentifier)")
        try? await process?.run(session: session)
      }
    }
  }
}
extension Array {
  subscript(safe index: Int) -> Element? {
    guard index < count else { return nil }
    return self[index]
  }
}
#else
struct TranslationModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
  }
}
#endif
