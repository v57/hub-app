#if DEBUG && os(macOS)
import CryptoKit
import Foundation
import HubService

@MainActor
enum HN604LiveAcceptance {
  static func run() async throws {
    let controller = try PacketTunnelController()
    let callerKey = try HubNetworkWireGuardKeyStore().publicKeyBase64()
    let remote = try configureRemotePeer(callerKey)
    defer { cleanupRemotePeer() }

    let grant = try makeGrant(
      callerWireGuardKey: callerKey,
      targetWireGuardKey: remote.publicKey
    )
    let authority = "s3-hn604.v1-test.hub.invalid"
    try await controller.install(
      configuration: HubNetworkProfileConfiguration(
        hubURL: URL(string: "wss://hub.invalid")!,
        hubNetworkID: grant.hubNetworkId,
        profilePublicKey: grant.callerKey,
        overlayIPv4Address: "\(grant.callerAddress)/32",
        overlayIPv6Address: "fd48:5542:4e45::3/128",
        dnsRecords: [
          HubNetworkDNSRecord(
            authority: authority,
            address: grant.destinationAddress
          )
        ],
        dnsServerAddress: grant.destinationAddress,
        trustedHubKey: grant.hubKey,
        wireGuardPublicKey: callerKey,
        connectionGrant: grant,
        peerEndpoint: "\(remote.address):51825"
      )
    )
    do {
      try await controller.start()
      for _ in 0..<100 {
        if await controller.status == .connected { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard await controller.status == .connected else {
        throw Error.tunnelNotConnected
      }

      let source = URL(string: "http://\(authority):9001/source.png?X-Amz-Signature=source")!
      let destination = URL(string: "http://\(authority):9001/upload?X-Amz-Signature=put")!
      let verification = URL(string: "http://\(authority):9001/verify?X-Amz-Signature=get")!
      try await HubService.Group.encodeImage(
        request: .init(
          from: source,
          to: destination,
          type: .jpeg,
          quality: 0.8
        )
      )
      let actual = try await HubService.Group.data(from: verification)
      let expectedDigest = try ssh(
        "sha256sum /tmp/hn604-upload.bin | cut -d' ' -f1"
      )
      let actualDigest = SHA256.hash(data: actual)
        .map { String(format: "%02x", $0) }
        .joined()
      guard actual.count > 2,
            actual.starts(with: [0xff, 0xd8]),
            actualDigest == expectedDigest else {
        throw Error.objectMismatch
      }
    } catch {
      await controller.stop()
      try? await controller.remove()
      throw error
    }
    await controller.stop()
    try await controller.remove()
  }

  private static func makeGrant(
    callerWireGuardKey: String,
    targetWireGuardKey: String
  ) throws -> ConnectionGrant {
    let signingKey = try KeyChain(
      .none,
      rawRepresentation: Data((0..<32).map(UInt8.init))
    )
    let hubKey = signingKey.publicKey()
    let now = Date()
    let unsigned = ConnectionGrant(
      grantId: "hn604-live-\(UUID().uuidString)",
      hubKey: hubKey,
      hubNetworkId: "hn604-live-network",
      callerKey: KeyChain.main.publicKey(),
      callerWireGuardKey: callerWireGuardKey,
      callerAddress: "100.96.0.3",
      targetKey: "hn604-ubuntu-agent",
      targetWireGuardKey: targetWireGuardKey,
      resourceId: "hn604-overlay-s3",
      providerId: "hn604-ubuntu-provider",
      protocol: .tcp,
      destinationAddress: "100.96.0.2",
      destinationPort: 9001,
      generation: 1,
      issuedAt: ISO8601DateFormatter.js.string(from: now),
      expiresAt: ISO8601DateFormatter.js.string(from: now.addingTimeInterval(240)),
      signature: ""
    )
    let input = try HubNetworkSignedEnvelope.signatureInput(
      for: unsigned,
      domain: "hub-network/connection-grant/v1"
    )
    let signature = try signingKey.signature(for: input).base64EncodedString()
    return ConnectionGrant(
      version: unsigned.version,
      grantId: unsigned.grantId,
      hubKey: unsigned.hubKey,
      hubNetworkId: unsigned.hubNetworkId,
      callerKey: unsigned.callerKey,
      callerWireGuardKey: unsigned.callerWireGuardKey,
      callerAddress: unsigned.callerAddress,
      targetKey: unsigned.targetKey,
      targetWireGuardKey: unsigned.targetWireGuardKey,
      resourceId: unsigned.resourceId,
      providerId: unsigned.providerId,
      protocol: unsigned.protocol,
      destinationAddress: unsigned.destinationAddress,
      destinationPort: unsigned.destinationPort,
      generation: unsigned.generation,
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      signature: signature
    )
  }

  private static func configureRemotePeer(
    _ callerKey: String
  ) throws -> (publicKey: String, address: String) {
    let python = """
    import base64
    import socket
    import struct
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from pathlib import Path
    source = base64.b64decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
    )
    upload = Path('/tmp/hn604-upload.bin')
    class Handler(BaseHTTPRequestHandler):
      def do_GET(self):
        body = upload.read_bytes() if self.path.startswith('/verify') and upload.exists() else source
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
      def do_PUT(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        upload.write_bytes(body); self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
      def log_message(self, *args): pass
    def serve_dns():
      sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
      sock.bind(('100.96.0.2', 53))
      while True:
        query, client = sock.recvfrom(4096)
        offset = 12
        while query[offset] != 0:
          offset += query[offset] + 1
        question_end = offset + 5
        query_type = struct.unpack('!H', query[offset + 1:offset + 3])[0]
        labels = []
        cursor = 12
        while query[cursor] != 0:
          size = query[cursor]
          cursor += 1
          labels.append(query[cursor:cursor + size].decode('ascii').lower())
          cursor += size
        name = '.'.join(labels)
        if name == 's3-hn604.v1-test.hub.invalid' and query_type == 1:
          header = query[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0)
          answer = b'\\xc0\\x0c' + struct.pack(
            '!HHIH4s', 1, 1, 30, 4, socket.inet_aton('100.96.0.2')
          )
          response = header + query[12:question_end] + answer
        else:
          rcode = 0 if name == 's3-hn604.v1-test.hub.invalid' else 3
          response = (
            query[:2] + struct.pack('!HHHHH', 0x8180 | rcode, 1, 0, 0, 0)
            + query[12:question_end]
          )
        sock.sendto(response, client)
    threading.Thread(target=serve_dns, daemon=True).start()
    HTTPServer(('100.96.0.2', 9001), Handler).serve_forever()
    """
    let encoded = Data(python.utf8).base64EncodedString()
    let output = try ssh("""
    set -e
    if [ -f /tmp/hn604-server.pid ]; then kill "$(cat /tmp/hn604-server.pid)" 2>/dev/null || true; fi
    ip link delete hn604 2>/dev/null || true
    rm -rf /tmp/hn604-wg
    mkdir -p /tmp/hn604-wg
    cd /tmp/hn604-wg
    apt-get download wireguard-tools >/dev/null 2>&1
    dpkg-deb -x wireguard-tools_*.deb root
    wgcmd=/tmp/hn604-wg/root/usr/bin/wg
    printf '%s' '\(encoded)' | base64 -d > /tmp/hn604_s3_server.py
    private="$("$wgcmd" genkey)"
    public="$(printf '%s' "$private" | "$wgcmd" pubkey)"
    keyfile="/etc/wireguard/hn604-private.key"
    mkdir -p /etc/wireguard
    printf '%s' "$private" > "$keyfile"
    chmod 600 "$keyfile"
    ip link add hn604 type wireguard
    ip address add 100.96.0.2/32 dev hn604
    "$wgcmd" set hn604 listen-port 51825 private-key "$keyfile" peer '\(callerKey)' allowed-ips 100.96.0.3/32
    ip link set hn604 up
    ip route add 100.96.0.3/32 dev hn604
    nohup python3 /tmp/hn604_s3_server.py >/tmp/hn604-server.log 2>&1 &
    echo $! >/tmp/hn604-server.pid
    printf '%s|%s' "$public" "88.99.151.50"
    """)
    let values = output.split(separator: "|", maxSplits: 1).map(String.init)
    guard values.count == 2 else { throw Error.remote(output) }
    return (values[0], values[1])
  }

  private static func cleanupRemotePeer() {
    _ = try? ssh("""
    if [ -f /tmp/hn604-server.pid ]; then kill "$(cat /tmp/hn604-server.pid)" 2>/dev/null || true; fi
    ip link delete hn604 2>/dev/null || true
    rm -f /etc/wireguard/hn604-private.key
    rm -rf /tmp/hn604-wg
    rm -f /tmp/hn604-server.pid /tmp/hn604_s3_server.py /tmp/hn604-upload.bin
    """)
  }

  private static func ssh(_ command: String) throws -> String {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    let knownHosts = FileManager.default.temporaryDirectory
      .appendingPathComponent("hn604-known-hosts")
    try """
    88.99.151.50 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICl80sp/1olgoiqOoL2crHE2WlxjN3mmEMfYIhMUL8fZ
    """.write(to: knownHosts, atomically: true, encoding: .utf8)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-o", "StrictHostKeyChecking=yes",
      "-o", "UserKnownHostsFile=\(knownHosts.path)",
      "root@88.99.151.50",
      "bash", "-s",
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    input.fileHandleForWriting.write(Data(command.utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    let text = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw Error.remote(
        String(
          decoding: error.fileHandleForReading.readDataToEndOfFile(),
          as: UTF8.self
        )
      )
    }
    return text
  }

  enum Error: Swift.Error {
    case tunnelNotConnected
    case objectMismatch
    case remote(String)
  }
}
#endif
