//
//  Screenshots.swift
//  Hub
//
//  Created by Linux on 04.06.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

struct ScreenshotsModeView: View {
  @State private var type = ""
  var body: some View {
    if #available(macOS 26.0, iOS 26.0, *) {
      NavigationStack {
        if let type = ProcessInfo.screenshotType {
          switch type {
          case .home:
            HomeView()
          case .image:
#if !os(tvOS)
            ImageEncoderView()
#endif
          case .video:
#if !os(tvOS)
            VideoEncoderView()
            #endif
          case .translate:
#if !os(tvOS) && !os(visionOS)
            TranslateView()
#endif
          case .chat:
#if !os(tvOS) && !os(visionOS)
            ChatView()
#endif
          case .pending:
            PendingListView()
          case .connections:
            UserConnections()
          case .lockdown:
            LockdownView()
          }
        }
      }.test()
    }
  }
}
extension ProcessInfo {
  static let screenshotType: ScreenshotPage? = {
    if let string = processInfo.environment["screenshot"] {
      return ScreenshotPage(rawValue: string)
    } else {
      return nil
    }
  }()
}
enum ScreenshotPage: String, CaseIterable {
  case home, image, video, translate, chat, pending, connections, lockdown
}
