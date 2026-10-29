//
//  Screenshots.swift
//  Hub
//
//  `screenshot=<page>` (Debug, the App Store screenshot tests in Tests/Screenshots.swift): the window with the `--demo`
//  hubs, open at that page as `--open` would open it.
//

#if DEBUG
import Foundation

enum ScreenshotPage: String, CaseIterable {
  case home, connections, requests, lockdown, translate, chat, image, video

  static let current: ScreenshotPage? = ProcessInfo.processInfo.environment["screenshot"].flatMap(ScreenshotPage.init)

  /// The page, as `--open` names it
  var open: String {
    switch self {
    case .home: "Home"
    case .connections, .requests, .lockdown: "Home/\(rawValue)"
    case .translate, .chat, .image, .video: "sharedServices"
    }
  }
  /// The service Shared Services shows tried
  var service: AppServices.Service? {
    switch self {
    case .translate: .translate
    case .chat: .chat
    case .image: .imageEncoder
    case .video: .videoEncoder
    case .home, .connections, .requests, .lockdown: nil
    }
  }
}
#endif
