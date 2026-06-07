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
  
  func test(page: ScreenshotPage, directory: URL) {
    let app = XCUIApplication()
    app.launchEnvironment = ["screenshot": "\(page)"]
    app.launch()
    defer { app.terminate() }
    Thread.sleep(forTimeInterval: 2)
    let index = (ScreenshotPage.allCases.firstIndex(where: { $0.rawValue == page.rawValue }) ?? 0) + 1
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(index).png"))
    try! XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(index).png"))
  }

  @MainActor
  func test() throws {
    let env = ProcessInfo.processInfo.environment
    let name = env["SIMULATOR_DEVICE_NAME"]!
      .replacingOccurrences(of: "Clone 1 of ", with: "")
    let home = env["SIMULATOR_HOST_HOME"]!
    let directory = URL(fileURLWithPath: "\(home)/Screenshots/\(name)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for page in ScreenshotPage.allCases {
      test(page: page, directory: directory)
    }
  }
}

enum ScreenshotPage: String, CaseIterable {
  case home, connections, pending, lockdown, translate, chat, image, video
}
