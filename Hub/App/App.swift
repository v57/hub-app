//
//  HubApp.swift
//  Hub
//
//  Created by Dmitry Kozlov on 17/2/25.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
import DefaultBackend
#else
import SwiftUI
#endif

@main
struct HubApp: App {
#if canImport(SwiftCrossUI)
  let backend = DefaultBackend()
#else
#if os(macOS)
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
#endif
  var body: some Scene {
    WindowGroup {
#if canImport(SwiftCrossUI)
      NavigationStack {
        HomeView().page()
      }
#else
      if ProcessInfo.isScreenshot {
        ScreenshotsModeView()
      } else if !ProcessInfo.isPreviews {
        NavigationStack {
          HomeView().page()
        }.modifier(TranslationModifier())
      }
#endif
    }
  }
}

#if os(macOS)
import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationDidBecomeActive(_ notification: Notification) {
    EventDelayManager.main.animate = true
  }
  func applicationDidResignActive(_ notification: Notification) {
    EventDelayManager.main.animate = false
  }
}
#endif

extension ProcessInfo {
  static let isPreviews: Bool = processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
  static let isScreenshot: Bool = processInfo.environment["screenshot"] != nil
}
