//
//  Screenshots.swift
//  Hub
//
//  Created by Linux on 04.06.26.
//

import SwiftUI

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
            ImageEncoderView()
          case .video:
            VideoEncoderView()
          case .translate:
            TranslateView()
          case .chat:
            ChatView()
          case .pending:
            PendingListView()
          case .connections:
            UserConnections()
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
  case home, image, video, translate, chat, pending, connections
}
