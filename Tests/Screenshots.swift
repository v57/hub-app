//
//  AppStoreScreenshotTests.swift
//  Tests
//
//  Created by Linux on 03.06.26.
//

import XCTest

final class ScreenshotTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }
  
  func test(page: ScreenshotPage) {
    let app = XCUIApplication()
    app.launchEnvironment = ["screenshot": "\(page)"]
    app.launch()
    defer { app.terminate() }
    Thread.sleep(forTimeInterval: 2)
    let index = (ScreenshotPage.allCases.firstIndex(where: { $0.rawValue == page.rawValue }) ?? 0) + 1
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(index)-\(page.rawValue).png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func test() throws {
    for page in ScreenshotPage.allCases {
      test(page: page)
    }
  }
}

enum ScreenshotPage: String, CaseIterable {
  case home, image, video, translate, chat, pending, connections, lockdown
}
