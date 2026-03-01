//
//  Video encoder service.swift
//  Hub
//
//  Created by Linux on 19.07.25.
//

import Foundation
import AVFoundation
import HubService
import Combine

extension HubService.Group {
  func videoService() -> Self {
    app(App(header: .init(type: .app, name: "Video Encoder", path: "video/encode/ui"), body: [
      .fileOperation(.init(title: nil, format: "mov", action: .init(path: "video/encode/hevc", body: .void)))
    ], data: [:]))
    .post("video/encode/hevc") { (request: EncodeRequest) in
      try await Self.encodeVideo(from: request.from, to: request.to)
    }
  }
  func imageService() -> Self {
    app(App(header: .init(type: .app, name: "Image Encoder", path: "image/encode/ui"), body: [
      .fileOperation(.init(title: nil, format: "$type", action: .init(path: "image/encode", body: .multiple(["type": "type", "quality": "quality"])))),
      .vstack(.init(content: [
        .hstack(.init(content: [
          .text(.init(value: "Quality", secondary: true)),
          .spacer(.init()),
          .slider(.init(value: "quality", min: 0.1, max: 1.0, step: 0.1)),
          .progress(.init(value: "quality")),
        ])),
        .hstack(.init(content: [
          .text(.init(value: "Result Format", secondary: true)),
          .spacer(.init()),
          .picker(.init(options: ["heic", "avif", "jpeg", "png"], selected: "type")),
        ])),
      ]))
    ], data: ["quality": .double(0.8), "type": .string("heic")]))
    .post("image/encode") { (request: EncodeImageRequest) in
      try await Self.encodeImage(request: request)
    }
  }
#if os(macOS) || os(iOS) || os(visionOS)
  func sensitiveContentService() -> Self {
    post("image/sensitive") { (url: URL) -> Bool in
      let file = try await Self.download(from: url)
      defer { file.delete() }
      return await file.isSensitive()
    }
  }
#endif
  struct EncodeRequest: Decodable, Sendable {
    let from: URL
    let to: URL
  }
  struct EncodeImageRequest: Decodable, Sendable {
    let from: URL
    let to: URL
    let type: ImageType
    let quality: Double
  }
  static func encodeImage(request: EncodeImageRequest) async throws {
    let data = try await data(from: request.from).image(format: request.type.rawValue, quality: request.quality, metadata: false)
    try await upload(data: data, to: request.to)
  }
  static func encodeVideo(from: URL, to: URL) async throws {
    let url = try await download(from: from)
    defer { url.delete() }
    let asset = AVURLAsset(url: url)
    let target = URL.temporaryDirectory.appending(path: UUID().uuidString + ".mov", directoryHint: .notDirectory)
    defer { target.delete() }
    try await VideoEncoder().encode(from: asset, to: target, settings: .hevc(quality: 0.6, size: nil, frameReordering: true)) { _, _ in }
    try await upload(file: target, to: to)
  }
  static func download(from: URL) async throws -> URL {
    let (tempDownload, _) = try await URLSession.shared.download(from: from)
    defer { tempDownload.delete() }
    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(from.lastPathComponent.components(separatedBy: ".").last!)", directoryHint: .notDirectory)
    try FileManager.default.moveItem(at: tempDownload, to: url)
    return url
  }
  static func data(from: URL) async throws -> Data {
    try await URLSession.shared.data(from: from).0
  }
  static func upload(file: URL, to: URL) async throws {
    var request = URLRequest(url: to)
    request.httpMethod = "PUT"
    defer { try? FileManager.default.removeItem(at: file) }
    _ = try await URLSession.shared.upload(for: request, fromFile: file)
  }
  static func upload(data: Data, to: URL) async throws {
    var request = URLRequest(url: to)
    request.httpMethod = "PUT"
    _ = try await URLSession.shared.upload(for: request, from: data)
  }
}

@MainActor
class AppServices {
  let hub: Hub
  var chat: HubService.Group?
  let video: HubService.Group
  let image: HubService.Group
#if os(macOS) || os(iOS) || os(visionOS)
  let sensitiveContent: HubService.Group
#endif
#if os(macOS) || os(iOS)
  var translation = TranslationGroups()
  @Published var translationEnabled = false
#endif
  private var enabled: Set<String> = [] {
    didSet {
      guard enabled != oldValue else { return }
      let list = enabled
      saveTask = Task {
        try await Task.sleep(for: .seconds(1))
        UserDefaults.standard.setValue(Array(list).sorted(), forKey: "services/\(hub.id)")
      }
    }
  }
  private var saveTask: Task<Void, Error>? {
    didSet { oldValue?.cancel() }
  }
  private var tasks = Set<AnyCancellable>()
  init(hub: Hub) {
    self.hub = hub
    enabled = Set(UserDefaults.standard.array(forKey: "services/\(hub.id)") as? [String] ?? [])
#if os(macOS) || os(iOS) || os(visionOS)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
      chat = hub.service.group(enabled: enabled.contains("text/llm")).chat()
    }
#endif
    video = hub.service.group(enabled: enabled.contains("video/encode")).videoService()
    image = hub.service.group(enabled: true).imageService()
#if os(macOS) || os(iOS) || os(visionOS)
    sensitiveContent = hub.service.group(enabled: enabled.contains("image/sensitive")).sensitiveContentService()
#endif
#if os(macOS) || os(iOS)
    if #available(macOS 15.0, iOS 18.0, *) {
      translationEnabled = enabled.contains("text/translate")
      translationGroups(enabled: $translationEnabled)
    }
#endif
    assign(chat?.$isEnabled, to: "text/llm")
    assign(video.$isEnabled, to: "video/encode")
    assign(image.$isEnabled, to: "image/encode")
#if os(macOS) || os(iOS)
    assign(sensitiveContent.$isEnabled, to: "image/sensitive")
    assign($translationEnabled, to: "text/translate")
#endif
  }
  private func save() {
    enabled = Set(UserDefaults.standard.array(forKey: "services/\(hub.id)") as? [String] ?? [])
  }
  private func assign(_ publisher: Published<Bool>.Publisher?, to key: String) {
    publisher?.sink { [unowned self] isEnabled in
      if isEnabled {
        enabled.insert(key)
      } else {
        enabled.remove(key)
      }
    }.store(in: &tasks)
  }
}
