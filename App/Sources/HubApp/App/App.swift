//
//  HubApp.swift
//  Hub
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import SwiftUI
import Foundation
import ComponentKit
#if os(macOS)
import AppKit
#endif

/// The app (Hub and Hub Pro, on every platform); its entry point is App/Sources/Hub/HubMain.swift.
public struct HubApp: App {
#if os(macOS)
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
  @Environment(\.scenePhase) private var scenePhase
  public init() {
#if DEBUG
    // Line by line, also into a file or `devicectl --console`, so a run's log reads as it goes
    setvbuf(stdout, nil, _IOLBF, 0)
#endif
#if canImport(PlatformCamera)
    CameraAlerts.handleOpens()
#endif
  }
  public var body: some Scene {
    WindowGroup {
      if !ProcessInfo.isPreviews {
#if DEBUG
        if HubReset.isRequested {
          Text("Resetting Hub…").task { await HubReset.run() }
        } else if CameraSelfTest.isRequested {
          Text("Camera self-test…").task { await CameraSelfTest.run() }
        } else if CameraPublishTest.isRequested {
          Text("Camera publish test…").task { await CameraPublishTest.run() }
        } else if ProcessInfo.processInfo.environment["HUB_HN9XX_OWNER_ACCEPTANCE"] != nil
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
#if os(macOS) || os(Linux) || os(Windows)
    .defaultSize(width: 1440, height: 900)
#endif
  }
  @ViewBuilder private var mainContent: some View {
    root.modifier(TranslationModifier())
      .onOpenURL { url in
        if !PairingRouter.main.open(url) {
          NetworkInvitationRouter.main.open(url)
        }
      }
#if canImport(PlatformCamera)
      // The security camera comes back on where the user left it on
      .task { SecurityCamera.main.restore() }
      // Motion alerts of the cameras this device follows
      .task { CameraAlerts.main.start() }
#endif
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
#if os(tvOS)
    TVRootView()
      .componentKit(accent: .hubAccent)
#else
    RootView()
#if os(iOS) && canImport(PlatformCamera)
      // The iPhone or iPad that is a camera: its black screen over the app
      .overlay {
        if SecurityCamera.main.showsScreen, SecurityCamera.main.phase == .on {
          CameraScreen()
        }
      }
#endif
      .kitToasts()
      .componentKit(accent: .hubAccent)
#endif
  }
}

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
  private var wake: Task<Void, Never>?

  func applicationDidFinishLaunching(_ notification: Notification) {
    wake = Task { @MainActor in
      for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
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
