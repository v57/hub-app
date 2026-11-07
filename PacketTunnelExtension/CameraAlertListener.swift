//
//  CameraAlertListener.swift
//  PacketTunnelExtension
//
//  Motion alerts on iPhone and iPad while the app is in the background, with no push service. iOS keeps this
//  extension running while Hub Network is on, so it follows the cameras the user picked (the app keeps them in a
//  keychain item: App's Camera alerts.swift writes it, `CameraAlertSubscription` there is the same JSON) and shows a
//  notification with the app's permission when a camera's `GET /alerts` says motion started.
//
//  The extension's own sockets don't go through its tunnel, so each connection requires the tunnel's virtual
//  interface (iOS 18); the camera's overlay address is reachable only there.
//

import Foundation
import HubService
import Network
import NetworkExtension
import UserNotifications

/// A camera the app follows (App's CameraAlertSubscription)
struct CameraAlertSubscription: Codable, Hashable, Sendable {
  var id: String
  var hub: String
  var hubName: String
  var place: String
  var host: String
  var port: UInt16
  var password: String
}

@available(iOS 18, macOS 15, *)
final class CameraAlertListener: @unchecked Sendable {
  /// A line of `GET /alerts` (App's CameraAlert)
  private struct Alert: Decodable {
    var kind: String
    var place: String?
    var device: String?
    var event: String?
  }

  /// One notification per camera at most this often (App's CameraAlerts.quietSeconds)
  static let quietSeconds: Double = 30
  /// The camera pings every 20 s: this long without a line means the connection is gone
  static let silence: Double = 60

  private let queue = DispatchQueue(label: "dev.v57.Hub.camera-alerts")
  private let interface: () -> NWInterface?
  private var followers: [CameraAlertSubscription: Follower] = [:]
  private var lastShown: [String: Date] = [:]

  init(interface: @escaping () -> NWInterface?) {
    self.interface = interface
  }

  /// Follows the cameras in the app's keychain item now: new ones start, removed or changed ones stop
  func reload() {
    let list = Self.stored()
    queue.async { [self] in
      let wanted = Set(list)
      for (subscription, follower) in followers where !wanted.contains(subscription) {
        follower.stop()
        followers[subscription] = nil
      }
      for subscription in wanted where followers[subscription] == nil {
        let follower = Follower(subscription: subscription, queue: queue, interface: interface) { [weak self] alert in
          self?.motion(alert, from: subscription)
        }
        followers[subscription] = follower
        follower.start()
      }
      extensionDiagnostics("camera alerts: following \(followers.count) camera\(followers.count == 1 ? "" : "s")")
    }
  }

  func stop() {
    queue.async { [self] in
      for follower in followers.values { follower.stop() }
      followers = [:]
    }
  }

  private static func stored() -> [CameraAlertSubscription] {
    let group = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String
    let item = KeyChain.KeychainConfiguration(
      service: "dev.v57.Hub.camera-alerts.v1", account: "subscriptions", accessGroup: group?.isEmpty == false ? group : nil,
      useDataProtectionKeychain: true)
    guard let data = try? KeyChain.loadData(keychain: item) else { return [] }
    return (try? JSONDecoder().decode([CameraAlertSubscription].self, from: data)) ?? []
  }

  // MARK: Notifications

  /// On the queue
  private func motion(_ alert: Alert, from subscription: CameraAlertSubscription) {
    let key = "\(subscription.hub)|\(subscription.id)"
    if let last = lastShown[key], Date().timeIntervalSince(last) < Self.quietSeconds { return }
    lastShown[key] = Date()
    extensionDiagnostics("camera alerts: motion at \(alert.place ?? subscription.place)")
    Fetch.get("/snapshot.jpg?width=640", from: subscription, queue: queue, interface: interface()) { image in
      Self.post(alert, from: subscription, image: image)
    }
  }

  /// Worded as the app's own (App's CameraAlerts.notification)
  private static func post(_ alert: Alert, from subscription: CameraAlertSubscription, image: Data?) {
    let content = UNMutableNotificationContent()
    content.title = "Motion at \(alert.place ?? subscription.place)"
    content.body = [alert.device, subscription.hubName].compactMap { $0 }.joined(separator: " · ")
    content.sound = .default
    content.threadIdentifier = "camera-\(subscription.id)"
    var info = ["hub": subscription.hub, "camera": subscription.id]
    if let event = alert.event { info["event"] = event }
    content.userInfo = info
    let id = "camera-\(subscription.id)-\(alert.event ?? UUID().uuidString)"
    if let image {
      let url = FileManager.default.temporaryDirectory.appending(path: "notification-\(UUID().uuidString).jpg")
      if (try? image.write(to: url)) != nil, let attachment = try? UNNotificationAttachment(identifier: id, url: url) {
        content.attachments = [attachment]
      }
    }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
      if let error { extensionDiagnostics("camera alerts: notification failed: \(error.localizedDescription)") }
    }
  }

  // MARK: Connections

  /// Keeps one camera's `GET /alerts` open through the tunnel, connecting again after it ends (2 s, doubling up to a
  /// minute) and after a minute of silence
  private final class Follower: @unchecked Sendable {
    let subscription: CameraAlertSubscription
    let queue: DispatchQueue
    let interface: () -> NWInterface?
    let onMotion: (Alert) -> Void
    private var connection: NWConnection?
    private var buffer = Data()
    private var headerRead = false
    private var lastHeard = Date()
    private var delay = 2.0
    private var stopped = false
    private var watchdog: DispatchSourceTimer?

    init(subscription: CameraAlertSubscription, queue: DispatchQueue, interface: @escaping () -> NWInterface?, onMotion: @escaping (Alert) -> Void) {
      self.subscription = subscription
      self.queue = queue
      self.interface = interface
      self.onMotion = onMotion
    }

    /// On the queue
    func start() {
      guard !stopped else { return }
      buffer = Data()
      headerRead = false
      lastHeard = Date()
      guard let connection = Fetch.connection(to: subscription, interface: interface()) else { return retry() }
      self.connection = connection
      connection.stateUpdateHandler = { [weak self, weak connection] state in
        guard let self, let connection, self.connection === connection else { return }
        switch state {
        case .ready:
          Fetch.send(Fetch.request("/alerts", for: self.subscription), on: connection)
          self.receive(on: connection)
        case .failed, .cancelled:
          self.ended(connection)
        default: break
        }
      }
      connection.start(queue: queue)
      if watchdog == nil {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
          guard let self, let connection = self.connection, Date().timeIntervalSince(self.lastHeard) > CameraAlertListener.silence else { return }
          connection.cancel()
        }
        timer.resume()
        watchdog = timer
      }
    }

    func stop() {
      stopped = true
      watchdog?.cancel()
      watchdog = nil
      connection?.cancel()
      connection = nil
    }

    private func receive(on connection: NWConnection) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
        guard let self, self.connection === connection else { return }
        if let content {
          self.lastHeard = Date()
          self.take(content)
        }
        if isComplete || error != nil {
          connection.cancel()
        } else {
          self.receive(on: connection)
        }
      }
    }

    private func take(_ data: Data) {
      buffer.append(data)
      if !headerRead {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<end.upperBound)
        guard head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else {
          extensionDiagnostics("camera alerts: \(subscription.place) answered \(head.split(separator: "\r\n").first ?? "")")
          connection?.cancel()
          return
        }
        headerRead = true
        delay = 2
        extensionDiagnostics("camera alerts: following \(subscription.place)")
      }
      while let newline = buffer.firstIndex(of: 10) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(...newline)
        if let alert = try? JSONDecoder().decode(Alert.self, from: line), alert.kind == "motion" { onMotion(alert) }
      }
    }

    private func ended(_ connection: NWConnection) {
      guard self.connection === connection else { return }
      self.connection = nil
      retry()
    }

    private func retry() {
      guard !stopped else { return }
      let wait = delay
      delay = min(delay * 2, 60)
      queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.start() }
    }
  }

  /// HTTP/1.1 over a connection that requires the tunnel's interface
  private enum Fetch {
    static func connection(to subscription: CameraAlertSubscription, interface: NWInterface?) -> NWConnection? {
      guard let interface, let port = NWEndpoint.Port(rawValue: subscription.port) else { return nil }
      let parameters = NWParameters.tcp
      parameters.requiredInterface = interface
      return NWConnection(host: NWEndpoint.Host(subscription.host), port: port, using: parameters)
    }

    static func request(_ path: String, for subscription: CameraAlertSubscription) -> Data {
      let host = subscription.host.contains(":") ? "[\(subscription.host)]" : subscription.host
      return Data("GET \(path) HTTP/1.1\r\nHost: \(host):\(subscription.port)\r\nAuthorization: Bearer \(subscription.password)\r\nConnection: close\r\n\r\n".utf8)
    }

    static func send(_ data: Data, on connection: NWConnection) {
      connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// A whole response's body (the server closes after it), or nil after 5 s or anything but 200
    static func get(_ path: String, from subscription: CameraAlertSubscription, queue: DispatchQueue, interface: NWInterface?, done: @escaping (Data?) -> Void) {
      guard let connection = connection(to: subscription, interface: interface) else { return done(nil) }
      var response = Data()
      var finished = false
      let finish: (Data?) -> Void = { body in
        guard !finished else { return }
        finished = true
        connection.cancel()
        done(body)
      }
      func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { content, _, isComplete, error in
          if let content { response.append(content) }
          if isComplete || error != nil {
            guard let end = response.range(of: Data("\r\n\r\n".utf8)),
                  String(decoding: response[..<end.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 200") else { return finish(nil) }
            finish(Data(response[end.upperBound...]))
          } else if response.count > 4 << 20 {
            finish(nil)
          } else {
            receive()
          }
        }
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          send(request(path, for: subscription), on: connection)
          receive()
        case .failed:
          finish(nil)
        default: break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + 5) { finish(nil) }
    }
  }
}
