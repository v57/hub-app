//
//  Translate service.swift
//  Hub
//
//  Created by Linux on 30.10.25.
//

import HubService
class TranslationGroups {
  var groups: [String: HubService.Group] = [:]
}

#if !canImport(SwiftCrossUI) && os(macOS) || os(iOS)
import Translation
import Combine

extension HubService.Group {
  @available(macOS 15.0, iOS 18.0, *)
  func translate(_ languages: LanguagePair) -> Self {
    post("text/translate/\(languages.sourceId.lowercased())/\(languages.targetId.lowercased())", options: .init(limit: 4)) { text in
      try await Statistics.updating(.translate) {
        try await Translation.main.translate(text: text, source: languages.sourceId, target: languages.targetId)
      }
    }.post("text/translate/\(languages.targetId.lowercased())/\(languages.sourceId.lowercased())", options: .init(limit: 4)) { text in
      try await Statistics.updating(.translate) {
        try await Translation.main.translate(text: text, source: languages.targetId, target: languages.sourceId)
      }
    }
  }
}
@available(macOS 15.0, iOS 18.0, *)
extension AppServices {
  func translationGroups() {
    observe()
  }
  private func observe() {
    guard let translation else { return }
    withObservationTracking {
      if let pairs = Translation.main.pairs {
        update(pairs: pairs, isEnabled: translation.isEnabled, translation: translation.item)
      }
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observe()
      }
    }
  }
  private func update(pairs: LanguageAvailability.Pairs, isEnabled: Bool, translation: TranslationGroups) {
    if isEnabled {
      if translation.groups.isEmpty {
        for pair in pairs.available {
          translation.groups[pair.id] = self.hub.service.group(enabled: true).translate(pair)
        }
        for pair in pairs.unavailable {
          translation.groups[pair.id] = self.hub.service.group(enabled: false).translate(pair)
        }
        self.hub.service.sendServiceUpdates()
      } else {
        for pair in pairs.available {
          translation.groups[pair.id]?.isEnabled = true
        }
        for pair in pairs.unavailable {
          translation.groups[pair.id]?.isEnabled = false
        }
      }
    } else {
      translation.groups.values.forEach { $0.isEnabled = false }
    }
  }
}
#endif
