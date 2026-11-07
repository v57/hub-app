//
//  Camera alerts.swift
//  Hub
//
//  Motion alerts with no push service. A device follows the cameras the user picked (Motion Alerts on a camera's page,
//  off until then): it keeps `GET /alerts` open on each camera's server over Hub Network and shows a notification of
//  its own when a line says motion started. Nothing goes through Apple's or anyone's push servers; the camera and the
//  follower talk directly, the way live view does.
//
//  Who listens: on a Mac (and iPhone or iPad before iOS 18) the app, while it runs. On iPhone and iPad with iOS 18 the
//  packet tunnel does, which iOS keeps running in the background while Hub Network is on: the app keeps the cameras'
//  addresses and passwords in a keychain item the tunnel reads (`CameraAlertSubscription`, the same JSON as
//  PacketTunnelExtension/CameraAlertListener.swift) and tells it when they change.
//

#if canImport(PlatformCamera)
import Foundation
import HubService
import PlatformHTTP
import PlatformNotifications

/// A camera this device follows, as the tunnel reads it (PacketTunnelExtension/CameraAlertListener.swift decodes it)
struct CameraAlertSubscription: Codable, Hashable, Sendable {
  /// The camera's Hub Network resource id
  var id: String
  /// The hub's address, and its name for the notification
  var hub: String
  var hubName: String
  /// The place it watches (Front Door)
  var place: String
  /// The camera device's overlay address and its server's port
  var host: String
  var port: UInt16
  var password: String

  var base: URL? { URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)") }
}

@MainActor @Observable
final class CameraAlerts {
  static let main = CameraAlerts()

  /// A camera page to open: a notification the user opened
  struct Open: Equatable {
    var hub: String
    var camera: String
    var event: String?
  }

  /// The cameras this device follows: hub address → camera resource id → place
  private(set) var followed: [String: [String: String]] {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(followed), forKey: Self.followedKey) }
  }
  /// Why alerts can't show, while they can't (notifications turned off for Hub)
  private(set) var problem: String?
  var pendingOpen: Open?

  /// The cameras' addresses and passwords as last resolved, by `key`: kept while a camera or its hub is away, since
  /// it usually comes back at the same address
  private var subscriptions: [String: CameraAlertSubscription] = [:]
  private var providers: [String: Task<Void, Never>] = [:]
  private var listeners: [String: (subscription: CameraAlertSubscription, task: Task<Void, Never>)] = [:]
  private var loop: Task<Void, Never>?
  private var lastShown: [String: Date] = [:]
  private var sentToTunnel: [CameraAlertSubscription]?

  private static let followedKey = "camera.alerts.v1"
  /// One notification per camera at most this often; the clips list has every event
  static let quietSeconds: Double = 30

  /// Whether the packet tunnel listens (iPhone and iPad with iOS 18: it connects through its own interface), not the app
  static var listensInTunnel: Bool {
#if os(iOS)
    if #available(iOS 18, *) { return true }
#endif
    return false
  }

  private init() {
    followed = UserDefaults.standard.data(forKey: Self.followedKey)
      .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
    for subscription in Self.stored() { subscriptions[Self.key(subscription.hub, subscription.id)] = subscription }
  }

  private static func key(_ hub: String, _ camera: String) -> String { "\(hub)|\(camera)" }

  func isFollowing(_ camera: HubCamera, on hub: Hub) -> Bool {
    followed[hub.id.absoluteString]?[camera.id] != nil
  }

  /// Turns a camera's alerts on or off on this device; asks for notifications right before the first one
  func setFollowing(_ on: Bool, _ camera: HubCamera, on hub: Hub) async {
    if on {
      guard await UserNotifications.requestPermission() else {
        problem = "Notifications are off for Hub. Turn them on in Settings, then try again."
        return
      }
      problem = nil
      followed[hub.id.absoluteString, default: [:]][camera.id] = camera.name
    } else {
      followed[hub.id.absoluteString]?[camera.id] = nil
      if followed[hub.id.absoluteString]?.isEmpty == true { followed[hub.id.absoluteString] = nil }
    }
    reconcile()
  }

  /// Opens a camera's page from a notification the user opened; set before launch ends, so the one that launched the
  /// app arrives too
  static func handleOpens() {
    UserNotifications.onOpen { info in
      guard let hub = info["hub"], let camera = info["camera"] else { return }
      CameraAlerts.main.open(Open(hub: hub, camera: camera, event: info["event"]))
    }
  }

  /// At launch: follows the cameras
  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled, let self {
        self.reconcile()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  private func open(_ target: Open) {
    pendingOpen = target
    if let hub = Hubs.main.list.first(where: { $0.id.absoluteString == target.hub }) { Navigator.main.open(hub, .cameras) }
  }

  // MARK: Following

  /// Follows each followed camera's providers on its hub while the hub is connected, and drops what's unfollowed
  private func reconcile() {
    var wanted = Set<String>()
    for (hubAddress, cameras) in followed {
      let hub = Hubs.main.list.first { $0.id.absoluteString == hubAddress }
      for (id, place) in cameras {
        let key = Self.key(hubAddress, id)
        wanted.insert(key)
        guard let hub, hub.isConnected, providers[key] == nil else { continue }
        providers[key] = Task { [weak self] in
          do {
            for try await list: [HubNetworkProvider] in hub.client.values("network/providers/list", CameraProviderRequest(resourceId: id)) {
#if DEBUG
              print("[CAMDRIVE] \(place) providers \(list.map { "\($0.overlayAddress):\($0.port)" }) password=\(CameraViewer.savedPassword(id: id) != nil)")
#endif
              self?.resolved(key, list, hub: hub, camera: id, place: place)
            }
          } catch {
#if DEBUG
            print("[CAMDRIVE] \(place) providers failed: \(error)")
#endif
          }
          self?.providers[key] = nil
        }
      }
    }
    for key in providers.keys where !wanted.contains(key) {
      providers.removeValue(forKey: key)?.cancel()
    }
    for key in subscriptions.keys where !wanted.contains(key) { subscriptions[key] = nil }
    apply()
  }

  private func resolved(_ key: String, _ list: [HubNetworkProvider], hub: Hub, camera: String, place: String) {
    // This device's own cameras need no alerts here; one away keeps its last address
    guard let provider = list.first, !SecurityCamera.main.units.values.contains(where: { $0.resourceId == camera }) else { return }
    let host = provider.key == hub.key ? "127.0.0.1" : provider.overlayAddress
    // The tunnel reaches only Hub Network
    if Self.listensInTunnel, host == "127.0.0.1" { return }
    guard let password = CameraViewer.savedPassword(id: camera), !password.isEmpty else { return }
    subscriptions[key] = CameraAlertSubscription(
      id: camera, hub: hub.id.absoluteString, hubName: hub.settings.name, place: place, host: host,
      port: UInt16(provider.port), password: password)
    apply()
  }

  /// Hands the subscriptions to whoever listens: the tunnel, or this app's own listeners
  private func apply() {
    if Self.listensInTunnel {
      let list = subscriptions.values.sorted { $0.id < $1.id }
      guard list != sentToTunnel else { return }
      sentToTunnel = list
      Self.store(list)
      Task {
        guard let tunnel = try? PacketTunnelController() else { return }
        try? await tunnel.reloadCameraAlerts()
      }
      return
    }
    for (key, listener) in listeners where subscriptions[key] != listener.subscription {
      listener.task.cancel()
      listeners[key] = nil
    }
    for (key, subscription) in subscriptions where listeners[key] == nil {
      let task = Task.detached {
        await Self.listen(subscription) { alert in
          await CameraAlerts.main.show(alert, from: subscription)
        }
      }
      listeners[key] = (subscription, task)
    }
  }

  // MARK: Listening in the app

  /// Keeps the camera's alerts open, connecting again after a failure (2 s, doubling up to a minute)
  nonisolated static func listen(
    _ subscription: CameraAlertSubscription, onMotion: @escaping @Sendable (CameraAlert) async -> Void
  ) async {
    guard let base = subscription.base else { return }
    var delay = 2.0
    while !Task.isCancelled {
      do {
        var request = URLRequest(url: base.appending(path: "alerts"))
        request.setValue("Bearer \(subscription.password)", forHTTPHeaderField: "Authorization")
        // A dead link shows as silence: the camera pings every 20 s
        request.timeoutInterval = CameraAlert.pingInterval * 3
        let (body, response) = try await HTTPBytes.response(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CameraViewerError.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
        delay = 2
        for try await line in body.lines {
          guard let alert = try? JSONDecoder.camera.decode(CameraAlert.self, from: Data(line.utf8)) else { continue }
          if alert.kind == .motion { await onMotion(alert) }
        }
      } catch {}
      try? await Task.sleep(for: .seconds(delay))
      delay = min(delay * 2, 60)
    }
  }

  private func show(_ alert: CameraAlert, from subscription: CameraAlertSubscription) async {
    let key = Self.key(subscription.hub, subscription.id)
    if let last = lastShown[key], Date().timeIntervalSince(last) < Self.quietSeconds { return }
    lastShown[key] = Date()
    let image = await Self.snapshot(subscription)
    do {
      try await UserNotifications.post(Self.notification(alert, from: subscription, image: image))
#if DEBUG
      print("[CAMDRIVE] alert shown: motion at \(alert.place ?? subscription.place), event \(alert.event ?? "-"), picture \(image?.count ?? 0) bytes")
#endif
    } catch {
#if DEBUG
      print("[CAMDRIVE] alert not shown: \(error.localizedDescription)")
#endif
    }
  }

#if DEBUG
  var debugState: String {
    "subscriptions=\(subscriptions.values.map { "\($0.place)@\($0.host):\($0.port)" }) providers=\(providers.count) listeners=\(listeners.count)"
  }
#endif

  /// What the tunnel shows too (CameraAlertListener.swift words it the same way)
  static func notification(_ alert: CameraAlert, from subscription: CameraAlertSubscription, image: Data?) -> UserNotification {
    let place = alert.place ?? subscription.place
    var info = ["hub": subscription.hub, "camera": subscription.id]
    if let event = alert.event { info["event"] = event }
    return UserNotification(
      id: "camera-\(subscription.id)-\(alert.event ?? UUID().uuidString)", title: "Motion at \(place)",
      body: [alert.device, subscription.hubName].compactMap { $0 }.joined(separator: " · "), thread: "camera-\(subscription.id)",
      image: image, info: info)
  }

  /// The camera's picture now, for the notification; nil when it doesn't come within 5 s
  nonisolated private static func snapshot(_ subscription: CameraAlertSubscription) async -> Data? {
    guard let base = subscription.base else { return nil }
    var components = URLComponents(url: base.appending(path: "snapshot.jpg"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "width", value: "640")]
    guard let url = components?.url else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.setValue("Bearer \(subscription.password)", forHTTPHeaderField: "Authorization")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return data
  }

  // MARK: The tunnel's keychain item

  private static var keychain: KeyChain.KeychainConfiguration {
    let group = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String
    return KeyChain.KeychainConfiguration(
      service: "dev.v57.Hub.camera-alerts.v1", account: "subscriptions", accessGroup: group?.isEmpty == false ? group : nil,
      useDataProtectionKeychain: true)
  }

  private static func stored() -> [CameraAlertSubscription] {
    guard listensInTunnel, let data = try? KeyChain.loadData(keychain: keychain) else { return [] }
    return (try? JSONDecoder().decode([CameraAlertSubscription].self, from: data)) ?? []
  }

  private static func store(_ list: [CameraAlertSubscription]) {
    guard let data = try? JSONEncoder().encode(list) else { return }
    try? KeyChain.replaceData(data, keychain: keychain)
  }
}
#endif
