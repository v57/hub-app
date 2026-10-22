//
//  HubApp.swift
//  Hub
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import SwiftUI
import Foundation
#if canImport(ComponentKit)
import ComponentKit
#endif
#if os(macOS)
import AppKit
import Combine
#endif

@main
struct HubApp: App {
#if os(macOS)
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      if ProcessInfo.isScreenshot {
        ScreenshotsModeView()
      } else if !ProcessInfo.isPreviews {
#if DEBUG
        if ProcessInfo.processInfo.environment["HUB_HN9XX_OWNER_ACCEPTANCE"] != nil
            || ProcessInfo.processInfo.environment["HUB_HN9XX_JOINER_ACCEPTANCE"] != nil {
          HN9xxAcceptanceView()
        } else if ProcessInfo.processInfo.environment["HUBTESTENV"] != nil {
#if os(macOS)
          NetworkTestingView()
#else
          mainContent
#endif
        } else if let target = ProcessInfo.processInfo.environment["HUB_OPEN_NETWORK"] {
          NetworkPageLaunch(target: target).page()
        } else if VPNProfileProbe.mode != nil {
          Text("VPN profile probe").task { await VPNProfileProbe.run() }
        } else {
          mainContent
        }
#else
        mainContent
#endif
      }
    }
#if os(macOS)
    .defaultSize(width: 1440, height: 900)
#endif
  }
  @ViewBuilder private var mainContent: some View {
    root.modifier(TranslationModifier())
#if !canImport(ComponentKit)
      .overlay { PairingConfirmation() }
#endif
      .onOpenURL { url in
        if !PairingRouter.main.open(url) {
          NetworkInvitationRouter.main.open(url)
        }
      }
#if canImport(HubServer)
      // The hub this device runs: started at launch when it's on, again after iOS suspended it
      .task { await LocalHub.main.resume() }
      .onChange(of: scenePhase) {
        switch scenePhase {
        case .active: Task { await LocalHub.main.resume() }
        case .background: LocalHub.main.enteredBackground()
        default: break
        }
      }
#endif
  }
  @ViewBuilder private var root: some View {
#if canImport(ComponentKit) && os(tvOS)
    TVRootView()
      .componentKit(accent: .hubAccent)
#elseif canImport(ComponentKit)
    RootView()
      .kitToasts()
      .componentKit(accent: .hubAccent)
#else
    NavigationStack {
      HomeView().page()
    }
#endif
  }
}

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
  private var wake: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { _ in
      Task { @MainActor in
        for hub in Hubs.main.list {
          hub.networkAppAgent.systemDidWake()
        }
      }
    }
  }

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
