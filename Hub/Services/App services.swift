//
//  Video encoder service.swift
//  Hub
//
//  Created by Linux on 19.07.25.
//

import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif
import HubService
import HubUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// RFC 3986 unreserved characters, matching Go's `url.QueryEscape` so the
/// signed `?e=` query round-trips through hub-net-node's canonical check.
private enum HubNetworkInvitationQuery {
  static let allowed: CharacterSet = {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return allowed
  }()
}

extension HubService.Group {
  /// Thread-safe box for the current hub-server `hub/net/node` value. The invite
  /// service handler is `@Sendable`, so it reads the endpoint from here
  /// instead of capturing MainActor hub state.
  final class HubNetworkNodeEndpointStore: @unchecked Sendable {
    static let shared = HubNetworkNodeEndpointStore()
    private let lock = NSLock()
    private var value = ""
    func set(_ endpoint: String) {
      lock.lock()
      defer { lock.unlock() }
      value = endpoint
    }
    func current() -> String {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  enum HubNetworkInviteError: LocalizedError {
    case inviterOffline
    case nodeNotSet
    var errorDescription: String? {
      switch self {
      case .inviterOffline: "This device is not registered with the Hub Network node yet."
      case .nodeNotSet: "This Hub has no Hub Network node. An owner has to set one before invitations work."
      }
    }
  }

  func hubNetworkAgentService(
    nodeEndpoint: @escaping @Sendable () -> String
      = { HubNetworkNodeEndpointStore.shared.current() },
    inviterOnline: @escaping @Sendable () async -> Bool = {
      await Task { @MainActor in
        (try? await PacketTunnelController().inviterStatus().registered) == true
      }.value
    }
  ) -> Self {
    post("net/invite", options: .init(permissions: .init(
      group: "Hub Network", name: "Invite to Hub Net"
    ))) { () -> String in
      // The node rejects joins while the extension's inviter is not
      // registered with it, so do not hand out a code that cannot work.
      let deadline = ContinuousClock.now + .seconds(10)
      while !(await inviterOnline()) {
        guard ContinuousClock.now < deadline else {
          throw HubNetworkInviteError.inviterOffline
        }
        try await Task.sleep(for: .milliseconds(250))
      }
      var nonce = UInt32.random(in: .min ... .max).bigEndian
      var expires = UInt32(Date().addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970).bigEndian
      let noncePart = withUnsafeBytes(of: &nonce) { Data($0).base64URLEncodedString() }
      let expiresPart = withUnsafeBytes(of: &expires) { Data($0).base64URLEncodedString() }
      let spki = Data(base64Encoded: KeyChain.main.publicKey())!
      let publicKey = Data(spki.suffix(32)).base64URLEncodedString()
      var payload = "\(publicKey).\(expiresPart).\(noncePart)"
      // Invitations carry their node: there is no default one
      let endpoint = nodeEndpoint()
      guard !endpoint.isEmpty else { throw HubNetworkInviteError.nodeNotSet }
      let escaped = endpoint.addingPercentEncoding(
        withAllowedCharacters: HubNetworkInvitationQuery.allowed
      ) ?? endpoint
      payload += "?e=" + escaped
      let signature = try KeyChain.main.signature(for: Data(payload.utf8)).base64URLEncodedString()
      return "\(payload)/\(signature)"
    }
  }
#if canImport(AVFoundation)
  func videoService() -> Self {
    app(App(header: .init(type: .app, name: "Video Encoder", path: "video/encode/ui"), body: [
      .text(.init(value: "This service will convert your videos to h265 (hevc) format", secondary: true)),
      .text(.init(value: "60% quality is a good for transfering over the internet", secondary: true)),
      .text(.init(value: "Select desired quality and drop some files. Processing will start automatically", secondary: true)),
      .vstack(.init(content: [
        .hstack(.init(content: [
          .text(.init(value: "Quality", secondary: true)),
          .spacer(.init()),
          .slider(.init(value: "quality", min: 0.1, max: 1.0, step: 0.1)),
          .progress(.init(value: "quality")),
        ])),
      ])),
      .fileOperation(.init(title: nil, format: "mov", action: .init(path: "video/encode/hevc", body: .void))),
    ], data: ["quality": .double(0.6)]))
    .post("video/encode/hevc", options: .init(limit: 6)) { (request: EncodeVideoRequest) in
      try await Statistics.updating(.videoEncoder) {
        try await Self.encodeVideo(request: request)
      }
    }
  }
#endif
#if canImport(ImageIO)
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
    .post("image/encode", options: .init(limit: 20)) { (request: EncodeImageRequest) in
      try await Statistics.updating(.imageEncoder) {
        try await Self.encodeImage(request: request)
      }
    }
  }
#endif
#if os(macOS) || os(iOS) || os(visionOS)
  func sensitiveContentService() -> Self {
    post("image/sensitive", options: .init(limit: 20)) { (url: URL) -> Bool in
      try await Statistics.updating(.sensitiveContent) {
        let file = try await Self.download(from: url)
        defer { file.delete() }
        return await file.isSensitive()
      }
    }
  }
#endif
#if canImport(ImageIO)
  struct EncodeImageRequest: Decodable, Sendable {
    let from: URL
    let to: URL
    let type: ImageType
    let quality: Double
  }
  static func encodeImage(request: EncodeImageRequest) async throws {
    try await Task.detached(name: "Image Encoding", priority: .userInitiated) {
      let data = try await data(from: request.from)
        .image(format: request.type.rawValue, quality: request.quality, metadata: false)
      try await upload(data: data, to: request.to)
    }.value
  }
#endif
#if canImport(AVFoundation)
  struct EncodeVideoRequest: Decodable, Sendable {
    let from: URL
    let to: URL
    let quality: Float
  }
  static func encodeVideo(request: EncodeVideoRequest) async throws {
    let url = try await download(from: request.from)
    defer { url.delete() }
    let asset = AVURLAsset(url: url)
    let target = URL.temporaryDirectory.appending(path: UUID().uuidString + ".mov", directoryHint: .notDirectory)
    defer { target.delete() }
    try await VideoEncoder().encode(from: asset, to: target, settings: .hevc(quality: request.quality, size: nil, frameReordering: true)) { _, _ in }
    try await upload(file: target, to: request.to)
  }
#endif
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

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

@MainActor
@Observable
class AppServices {
  let hub: Hub
  var chat: Status<HubService.Group>?
  var video: Status<HubService.Group>?
  var image: Status<HubService.Group>?
  var sensitiveContent: Status<HubService.Group>?
  var translation: Status<TranslationGroups>?
  private var enabled: Set<Service> = [] {
    didSet {
      guard enabled != oldValue else { return }
      let list = enabled
      saveTask = Task {
        try await Task.sleep(for: .seconds(1))
        UserDefaults.standard.set(list.map(\.id).sorted(), forKey: "services/\(hub.id)")
      }
    }
  }
  private var saveTask: Task<Void, Error>? {
    didSet { oldValue?.cancel() }
  }
  init(hub: Hub) {
    self.hub = hub
    enabled = Set((UserDefaults.standard.array(forKey: "services/\(hub.id)") as? [String] ?? []).compactMap { Service(id: $0) })
#if os(macOS) || os(iOS) || os(visionOS)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
      chat = Status(services: self, service: .chat) {
        hub.service.group(enabled: $0).chat()
      } update: { $0.isEnabled = $1 }
    }
#endif
#if canImport(AVFoundation)
    video = Status(services: self, service: .videoEncoder) {
      hub.service.group(enabled: $0).videoService()
    } update: { $0.isEnabled = $1 }
#endif
#if canImport(ImageIO)
    image = Status(services: self, service: .imageEncoder) {
      hub.service.group(enabled: $0).imageService()
    } update: { $0.isEnabled = $1 }
#endif
#if os(macOS) || os(iOS) || os(visionOS)
    sensitiveContent = Status(services: self, service: .sensitiveContent) {
      hub.service.group(enabled: $0).sensitiveContentService()
    } update: { $0.isEnabled = $1 }
#endif
#if os(macOS) || os(iOS)
    if #available(macOS 15.0, iOS 18.0, *) {
      translation = Status(services: self, service: .translate) { _ in
        TranslationGroups()
      } update: { groups, isEnabled in
        groups.groups.values.forEach { $0.isEnabled = isEnabled }
      }
      translationGroups()
    }
#endif
  }
  @MainActor
  @Observable
  class Status<Item> {
    unowned var services: AppServices
    let service: Service
    var isEnabled: Bool {
      didSet {
        guard isEnabled != oldValue else { return }
        if isEnabled {
          services.enabled.insert(service)
        } else {
          services.enabled.remove(service)
        }
        update(item, isEnabled)
      }
    }
    let item: Item
    let update: (Item, Bool) -> Void
    init(services: AppServices, service: Service, create: (Bool) -> Item, update: @escaping (Item, Bool) -> Void) {
      let isEnabled = services.enabled.contains(service)
      self.services = services
      self.service = service
      self.isEnabled = isEnabled
      self.update = update
      self.item = create(isEnabled)
    }
  }
}
