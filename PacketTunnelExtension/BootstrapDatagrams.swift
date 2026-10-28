import Foundation

/// The HUBB datagrams that reach WireGuard's socket (`bootstrapBind` in WireGuardKitGo): a joiner's request goes to
/// this device's inviter, a response or error to the joiner exchange waiting for its request id.
///
/// Running the direct bootstrap exchange on WireGuard's socket keeps it on the one NAT mapping the node observed and
/// WireGuard uses right after, so a joiner on another network (a phone on cellular) reaches an inviter behind NAT (a
/// Mac at home) at the address the node saw it at, through the hole the inviter's punch opened.
final class BootstrapDatagrams: @unchecked Sendable {
  private let lock = NSLock()
  private var onRequest: ((String, Data) -> Void)?
  private var waiters: [Data: (String, Data) -> Void] = [:]

  func setRequestHandler(_ handler: ((_ source: String, _ datagram: Data) -> Void)?) {
    lock.withLock { onRequest = handler }
  }

  func wait(for requestID: Data, _ handler: @escaping (_ source: String, _ datagram: Data) -> Void) {
    lock.withLock { waiters[requestID] = handler }
  }

  func stopWaiting(for requestID: Data) {
    lock.withLock { waiters[requestID] = nil }
  }

  /// A frame's header: magic (4), version (1), type (1), request id (16). Anything shorter, such as an inviter's punch,
  /// is dropped.
  func receive(source: String, datagram: Data) {
    guard datagram.count >= 22 else { return }
    let header = [UInt8](datagram.prefix(22))
    switch header[5] {
    case 1:
      lock.withLock { onRequest }?(source, datagram)
    case 2, 3:
      lock.withLock { waiters[Data(header[6..<22])] }?(source, datagram)
    default:
      break
    }
  }

  /// What an inviter sends toward a joiner to open its own NAT for the joiner's request: the HUBB magic, so the
  /// joiner's WireGuard never sees it, and too short to be a frame
  static let punch = Data("HUBB".utf8) + Data([1, 0])
}
