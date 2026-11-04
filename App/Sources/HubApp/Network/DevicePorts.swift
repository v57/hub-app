import Foundation

/// This device's own say over which of its ports another device may open over Hub Network (hub-net's `deviceports`).
/// A hub-signed grant names ports; the tunnel opens only those also on this list, so a Hub can narrow what's reachable
/// but never widen it. It holds what this device itself put there: shares attested here (this Mac's services, the
/// camera), kept 31 days from the last attestation so a restart doesn't close them, ports the user allowed, the Hub's
/// port when the Hub runs on this device, and the SSH port only when the user turned it on. An attestation doesn't
/// count for the SSH port: another process of this user can't turn SSH on.
///
/// The app hands the list to the extension with each `network/links`, replacing whatever the Hub sent in its place.
final class DevicePorts: @unchecked Sendable {
  struct Port: Codable, Hashable, Sendable {
    let `protocol`: String
    let port: UInt16

    var title: String { "\(`protocol`)/\(port)" }

    init(protocol: String, port: UInt16) {
      self.protocol = `protocol`
      self.port = port
    }

    /// `tcp/8080`
    init?(_ text: String) {
      let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "/")
      guard parts.count == 2, ["tcp", "udp"].contains(parts[0]), let port = UInt16(parts[1]), port != 0 else { return nil }
      self.init(protocol: String(parts[0]), port: port)
    }
  }

  private struct Attested: Codable {
    let port: Port
    let at: Date
  }

  private struct State: Codable {
    var ssh = false
    var sshPort: UInt16 = 22
    var allowed: [Port] = []
    var attested: [Attested] = []
    /// What a Hub on this device already opened was taken once, when this list was new
    var seeded = false
  }

  static let main = DevicePorts(defaults: .standard)
  static let attestedLifetime: TimeInterval = 31 * 24 * 3600
  private static let maximumAttested = 256
  private static let key = "hubnet.devicePorts"

  private let lock = NSLock()
  private let defaults: UserDefaults
  private let now: () -> Date
  private var state: State

  init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.now = now
    state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
  }

  private func change(_ edit: (inout State) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    edit(&state)
    if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
  }

  private func read<T>(_ value: (State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return value(state)
  }

  var isSSHEnabled: Bool { read(\.ssh) }
  var sshPort: UInt16 { read(\.sshPort) }
  var allowed: [Port] { read(\.allowed) }

  func setSSH(_ enabled: Bool) { change { $0.ssh = enabled } }
  func allow(_ port: Port) { change { if !$0.allowed.contains(port) { $0.allowed.append(port) } } }
  func remove(_ port: Port) { change { $0.allowed.removeAll { $0 == port } } }

  /// A share on this port was attested here
  func noteAttested(protocol networkProtocol: String, port: UInt16) {
    let entry = Attested(port: Port(protocol: networkProtocol, port: port), at: now())
    change { state in
      state.attested.removeAll { $0.port == entry.port || entry.at.timeIntervalSince($0.at) >= Self.attestedLifetime }
      state.attested = Array(state.attested.sorted { $0.at > $1.at }.prefix(Self.maximumAttested - 1)) + [entry]
    }
  }

  /// A Hub on this very device is the device's own: what it already opened keeps working, SSH included, once. A device
  /// from before this list had no other record of it. Later grants can't add to it.
  func seedFromOwnHub(_ ports: [Port]) {
    change { state in
      guard !state.seeded, !ports.isEmpty else { return }
      state.seeded = true
      for port in Set(ports) where !state.allowed.contains(port) {
        if port.protocol == "tcp", port.port == state.sshPort {
          state.ssh = true
        } else {
          state.allowed.append(port)
        }
      }
    }
  }

  /// What the tunnel lets open. `hubPort` is the Hub's port when the Hub runs on this device
  func list(hubPort: UInt16?) -> [Port] {
    read { state in
      let ssh = Port(protocol: "tcp", port: state.sshPort)
      var ports = Set(state.allowed)
      let date = now()
      for entry in state.attested where entry.port != ssh && date.timeIntervalSince(entry.at) < Self.attestedLifetime {
        ports.insert(entry.port)
      }
      if state.ssh { ports.insert(ssh) }
      if let hubPort { ports.insert(Port(protocol: "tcp", port: hubPort)) }
      return ports.sorted { ($0.port, $0.protocol) < ($1.port, $1.protocol) }
    }
  }

  /// Whether `host` is this device: loopback or one of its own addresses. A Hub says `hubHost` itself, so that counts
  /// for nothing here.
  static func isThisDevice(host: String) -> Bool {
    let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return true }
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return false }
    defer { freeifaddrs(list) }
    var current = list
    while let entry = current {
      defer { current = entry.pointee.ifa_next }
      guard let address = entry.pointee.ifa_addr else { continue }
      let family = Int32(address.pointee.sa_family)
      guard family == AF_INET || family == AF_INET6 else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
      if getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
         String(cString: buffer).split(separator: "%").first.map(String.init)?.lowercased() == host {
        return true
      }
    }
    return false
  }
}
