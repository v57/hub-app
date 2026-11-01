//
//  Camera publish test.swift
//  Hub
//
//  Debug: `Hub --camera-publish-test` publishes the camera's share the way `SecurityCamera` does, on a hub that runs
//  in-process (Core/HubServer) with a temporary folder: this app binds as its device's agent, signs the share's
//  attestation itself, and reads the camera back as a viewer would. No tunnel or camera is used. It prints `[CAMERA]`
//  lines and quits.
//

#if DEBUG && canImport(PlatformCamera) && canImport(HubServer)
import Foundation
import HubServer
import HubService
import PlatformCamera

@MainActor
enum CameraPublishTest {
  static var isRequested: Bool { CommandLine.arguments.contains("--camera-publish-test") }

  private struct Bind: Encodable {
    let version = 1
    let bindingKind = "apple-app"
    let wireGuardKey: String
    let name = "Camera publish test"
    let platform: String
    let overlayAddresses: [String] = []
    let connectedAt = ISO8601DateFormatter().string(from: Date())
  }

  private struct Bound: Decodable {
    struct Profile: Decodable {
      let key: String
      let overlayAddresses: [String]
    }
    let success: Bool
    let profile: Profile
  }

  private struct ProvidersRequest: Encodable {
    let resourceId: String
  }

  static func run() async {
    var failures = 0
    func check(_ ok: Bool, _ line: String) {
      CameraSelfTest.log("\(ok ? "ok" : "FAIL") \(line)")
      if !ok { failures += 1 }
    }
    let folder = URL.temporaryDirectory.appending(path: "camera-hub-\(UUID().uuidString.prefix(6))")
    var configuration = HubServer.Configuration(dataDirectory: folder)
    configuration.listen = ListenAddress(port: 0)
    configuration.name = "Camera test"
    configuration.host = "app"
    configuration.owners = [KeyChain.main.publicKey()] + (DeviceIdentity.app.map { [$0.key.publicKey] } ?? [])
    configuration.devicePublicKey = DeviceIdentity.app?.key.publicKey
    configuration.pairsAtStart = false
    configuration.log = { _ in }
    let server = HubServer(configuration)
    do {
      let port = try await server.start()
      CameraSelfTest.log("hub on \(port)")
      let client = HubClient(URL(string: "ws://127.0.0.1:\(port)")!, keyChain: .main, options: .init(
        hubKey: server.status.hubKey, hubKeys: HubKeyPins(.memory), device: .app, instance: "Hub"))
      let network = client.service.network
      let key = KeyChain.main.publicKey()

      let wireGuardKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
      let bound: Bound = try await client.send("hub/net/bind", Bind(wireGuardKey: wireGuardKey, platform: AppDevice.platform), timeout: 10)
      check(bound.success, "bound as this device’s agent at \(bound.profile.overlayAddresses)")

      let identity = KeyChain.main
      network.setAttestationProvider { share, serviceKey, _ in
        try CameraShareAttestation.attest(share, serviceKey: serviceKey, identity: identity)
      }
      let shareName = HubCamera.sharePrefix + "Test"
      let share = NetworkShare(name: shareName, protocol: .tcp, target: LocalTarget(port: 45_678), policy: .hub)
      // The client takes shares a moment after it connects; the camera's connection watch retries the same way
      var publications: [NetworkSharePublication] = []
      for attempt in 1...10 {
        do {
          publications = try await network.publish(share)
          break
        } catch where attempt < 10 {
          try await Task.sleep(for: .milliseconds(500))
        }
      }
      let resourceId = network.publication(forShare: shareName)?.resourceId
      check(resourceId != nil && publications.contains { $0.resourceId == resourceId }, "the hub took the share: \(publications.map(\.resourceId))")

      // A second publish within the attestation's lifetime gets a new attestation id
      _ = try await network.republish()
      check(network.publication(forShare: shareName)?.resourceId == resourceId, "republished")

      let resources: [HubNetworkResource] = try await first(client.values("network/resource/list"))
      let cameras = resources.compactMap(HubCamera.init)
      check(cameras.map(\.name) == ["Test"] && cameras.first?.id == resourceId, "listed as camera \(cameras.map(\.name))")

      if let resourceId {
        let providers: [HubNetworkProvider] = try await first(client.values("network/providers/list", ProvidersRequest(resourceId: resourceId)))
        check(providers.count == 1 && providers.first?.port == 45_678, "one provider on port \(providers.map(\.port))")
        // The viewer goes to loopback for its own device's camera
        check(providers.first?.key == key, "the provider is this app's key (viewer uses loopback)")
        check(providers.first.map { $0.overlayAddress.hasPrefix("100.") } == true, "overlay address \(providers.map(\.overlayAddress))")
      }

      _ = try await network.remove(shareName)
      if let resourceId {
        let providers: [HubNetworkProvider] = try await first(client.values("network/providers/list", ProvidersRequest(resourceId: resourceId)))
        check(providers.isEmpty, "turned off: no provider")
      }
      client.stop()
    } catch {
      CameraSelfTest.log("FAIL \(error)")
      failures += 1
    }
    await server.stop()
    try? FileManager.default.removeItem(at: folder)
    CameraSelfTest.log(failures == 0 ? "result passed" : "result failed \(failures)")
    exit(failures == 0 ? 0 : 1)
  }

  private static func first<S: AsyncSequence>(_ values: S) async throws -> S.Element {
    for try await value in values { return value }
    throw CameraError.failed("The stream ended.")
  }
}
#elseif DEBUG
@MainActor
enum CameraPublishTest {
  static var isRequested: Bool { false }
  static func run() async {}
}
#endif
