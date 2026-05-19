//
//  Translate service.swift
//  Hub
//
//  Created by Linux on 30.10.25.
//

#if os(macOS) || os(iOS)
import HubService
import Translation
import Combine

extension HubService.Group {
  @available(macOS 15.0, iOS 18.0, *)
  func translate(_ languages: LanguageAvailability.LanguagePair) -> Self {
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
struct TranslationGroups {
  var groups: [String: HubService.Group] = [:]
  var groupsSubscription: AnyCancellable?
}
extension AppServices {
  @available(macOS 15.0, iOS 18.0, *)
  func translationGroups(enabled: Published<Bool>.Publisher) {
    translation.groupsSubscription = Translation.main.$pairs.compactMap { $0 }.combineLatest(enabled).sink { [weak self] pairs, isEnabled in
      guard let self else { return }
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
}
#endif
