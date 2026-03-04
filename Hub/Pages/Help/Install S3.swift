//
//  Install S3.swift
//  Hub
//
//  Created by Linux on 05.11.25.
//

import SwiftUI

struct InstallS3: View {
  typealias CodeView = InstallationGuide.CodeView
  @Environment(Hub.self) var hub
  enum Guide {
    case host, local, manual
  }
  @State var installer = Installer()
  @State var guide: Guide = .local
  @State var open = false
  var body: some View {
    if open {
      StorageView().transition(.blurReplace)
    } else {
      ScrollView {
        VStack(alignment: .leading) {
          Picker("Storage Options", selection: $guide) {
            Text("Local").tag(Guide.local)
            Text("Cloud").tag(Guide.host)
            Text("Connect").tag(Guide.manual)
          }.pickerStyle(.segmented).labelsHidden()
          switch guide {
          case .local:
            Share(open: $open)
          case .manual:
            Connect(open: $open)
          case .host:
            Host(open: $open)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).safeAreaPadding(.horizontal)
      }.task {
        installer.set(hub: hub)
      }.navigationTitle("Connect Storage").environment(installer)
        .transition(.blurReplace)
    }
  }
  struct Host: View {
    @Environment(Installer.self) private var installer
    @State private var bucketName: String = ""
    @State private var region: Region?
    @State private var accessKey: String = ""
    @State private var secretKey: String = ""
    private var isReady: Bool {
      !bucketName.isEmpty && region != nil && !accessKey.isEmpty && !secretKey.isEmpty
    }
    
    @Binding var open: Bool
    var body: some View {
      Section(number: 0, title: "Wasabi Cloud Storage") {
        HStack {
          Text("30 day trial")
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemFill).opacity(0.4), in: .capsule)
          Text("$7 / TB / month")
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemFill).opacity(0.4), in: .capsule)
        }.fontWeight(.medium)
        Text("""
          Hub is not associated with Wasabi
          I think Wasabi is the cheapest S3 service on the market
          If you know any better, please leave a message in Discord and i will replace it in the next update!
          """).secondary()
      }
      Section(number: 1, title: "Create account") {
        Text("""
1. Go to [Wasabi](https://wasabi.com) Website and create account
2. Login
""")
      }
      Section(number: 2, title: "Create bucket") {
        Text("""
1. Go to [Buckets](https://console.wasabisys.com/file_manager)
2. Click **Create bucket**
3. Name your bucket (you can put anything)
4. Select server
5. Fill data in the fields below
""")
        TextField("Bucket Name", text: $bucketName).keyboard(style: .code)
          .frame(maxWidth: 400)
        Picker("Server region", selection: $region) {
          ForEach(Region.allCases, id: \.self) { region in
            Text("\(region.flag) \(region.name)").tag(region)
          }
        }
      }
      Section(number: 3, title: "Create access key for your service") {
        Text("""
1. Go to [Access Keys](https://console.wasabisys.com/access_keys)
2. Click **Create Access Key**
3. Click **Create**
4. Enter **Access Key** and **Secret Key** in the fields below 
""")
        TextField("Access Key", text: $accessKey).frame(maxWidth: 400)
          .keyboard(style: .code)
        TextField("Secret Key", text: $secretKey).frame(maxWidth: 400)
          .keyboard(style: .code)
        CreationButtons(settings: settings)
      }
    }
    var settings: Hub.Launcher.AppSettings? {
      guard isReady else { return nil }
      guard let region else { return nil }
      return .s3(access: accessKey, secret: secretKey, region: region.region, endpoint: region.endpoint, bucket: bucketName)
    }
    enum Region: CaseIterable {
      case tokyo, osaka, singapore, sydney, toronto, amsterdam, frankfurt, milan, unitedKingdom, paris, unitedKingdom2, texas, nVirginia, nVirginia2, oregon, sanJose
      var name: String {
        switch self {
        case .tokyo: "Tokyo ap-northeast-1"
        case .osaka: "Osaka ap-northeast-2"
        case .singapore: "Singapore ap-southeast-1"
        case .sydney: "Sydney ap-southeast-2"
        case .toronto: "Toronto ca-central-1"
        case .amsterdam: "Amsterdam eu-central-1"
        case .frankfurt: "Frankfurt eu-central-2"
        case .milan: "Milan eu-south-1"
        case .unitedKingdom: "United Kingdom eu-west-1"
        case .paris: "Paris eu-west-2"
        case .unitedKingdom2: "United Kingdom eu-west-3"
        case .texas: "Texas us-central-1"
        case .nVirginia: "N. Virginia us-east-1"
        case .nVirginia2: "N. Virginia us-east-2"
        case .oregon: "Oregon us-west-1"
        case .sanJose: "San Jose us-west-2"
        }
      }
      var region: String {
        switch self {
        case .tokyo:"ap-northeast-1"
        case .osaka:"ap-northeast-2"
        case .singapore:"ap-southeast-1"
        case .sydney:"ap-southeast-2"
        case .toronto:"ca-central-1"
        case .amsterdam:"eu-central-1"
        case .frankfurt:"eu-central-2"
        case .milan:"eu-south-1"
        case .unitedKingdom:"eu-west-1"
        case .paris:"eu-west-2"
        case .unitedKingdom2:"eu-west-3"
        case .texas:"us-central-1"
        case .nVirginia:"us-east-1"
        case .nVirginia2:"us-east-2"
        case .oregon:"us-west-1"
        case .sanJose:"us-west-2"
        }
      }
      var flag: String {
        switch self {
        case .tokyo:"🇯🇵"
        case .osaka:"🇯🇵"
        case .singapore:"🇸🇬"
        case .sydney:"🇦🇺"
        case .toronto:"🇨🇦"
        case .amsterdam:"🇳🇱"
        case .frankfurt:"🇩🇪"
        case .milan:"🇪🇸"
        case .unitedKingdom:"🇬🇧"
        case .paris:"🇫🇷"
        case .unitedKingdom2:"🇬🇧"
        case .texas:"🇺🇸"
        case .nVirginia:"🇺🇸"
        case .nVirginia2:"🇺🇸"
        case .oregon:"🇺🇸"
        case .sanJose:"🇺🇸"
        }
      }
      var endpoint: String {
        if self == .nVirginia {
          return "https://s3.wasabisys.com"
        } else {
          return "https://s3.\(region).wasabisys.com"
        }
      }
    }
  }
  struct Section<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View {
      HStack(alignment: .firstTextBaseline) {
        Text("\(number).").font(.title3).fontWeight(.bold)
        VStack(alignment: .leading) {
          Text(title).font(.title3).fontWeight(.bold)
            .padding(.bottom, 2)
          content
        }
      }.padding(.top)
    }
  }
  struct Share: View {
    @Environment(Installer.self) private var installer
    @Environment(Hub.self) private var hub
    @HubState(\.launcherInfo) private var info
    @HubState(\.hostPending) private var pending
    @State private var running = false
    @State private var testFailed: Bool?
    
    @Binding var open: Bool
    var body: some View {
      Text("Share your local directory").font(.title3).fontWeight(.bold)
      Text("Install storage service from your **Hub Launcher**")
      CodeView(title: "Shared Directory", "~/Hub/Files")
      Text("Only this directory will be shared")
      let status = status
      ZStack {
        if let error = status.error {
          Text(error).foregroundStyle(.red).transition(.blurReplace)
        } else if let title = status.action(running: running) {
          AsyncButton(title) {
            try await action(status: status)
          }.transition(.blurReplace).buttonStyle(.borderedProminent)
        }
      }.contentTransition(.numericText())
    }
    var canCreate: Bool { hub.require(permissions: "launcher/app/create") }
    var canReadFiles: Bool { hub.require(permissions: "s3/read") }
    var canAllow: Bool { hub.require(permissions: "hub/host/update") }
    var pendingItem: PendingList.Item? {
      pending.list.last(where: { $0.pending.first?.starts(with: "s3") ?? false } )
    }
    var status: Status {
      if canReadFiles {
        if let testFailed {
          return testFailed ? .test : .tested
        } else {
          return .test
        }
      } else {
        guard canCreate else { return .cantCreate }
        if let pendingItem {
          if canAllow {
            return .allow(pendingItem)
          } else {
            return .cantAllow
          }
        } else {
          return .create
        }
      }
    }
    func action(status: Status) async throws {
      guard !running else { return }
      running = true
      testFailed = false
      defer { running = false }
      switch status {
      case .create:
        try await hub.launcher.createLocal()
      case .allow(let item):
        try await hub.host.allow(key: item.id, paths: item.pending)
      case .test:
        do {
          try await hub.client.send("s3/list")
          testFailed = false
        } catch {
          testFailed = true
        }
      case .tested:
        withAnimation {
          open = true
        }
      case .cantCreate: break
      case .cantAllow: break
      }
    }
    enum Status: Hashable {
      case create, allow(PendingList.Item), test, tested, cantCreate, cantAllow
      func action(running: Bool) -> LocalizedStringKey? {
        switch self {
        case .create: running ? "Creating..." : "Create"
        case .allow: running ? "Allowing..." : "Allow"
        case .test: running ? "Testing..." : "Test"
        case .tested: "Open Files"
        case .cantCreate, .cantAllow: nil
        }
      }
      var error: LocalizedStringKey? {
        switch self {
        case .create, .allow, .test, .tested: nil
        case .cantCreate: "You don't have permissions to install services"
        case .cantAllow: "Ask hub owner to give access to Local Storage service"
        }
      }
    }
  }
  struct Connect: View {
    @Environment(Installer.self) private var installer
    @State private var bucketName: String = ""
    @State private var region: String = ""
    @State private var endpoint: String = ""
    @State private var accessKey: String = ""
    @State private var secretKey: String = ""
    @Binding var open: Bool
    var body: some View {
      Text("Use this page if you use other S3 services like AWS, Azure, Google Cloud and so on")
      TextField("Endpoint", text: $endpoint).keyboard(style: .url)
      TextField("Region", text: $region).keyboard(style: .code)
      TextField("Bucket name", text: $bucketName).keyboard(style: .code)
      TextField("Access Key", text: $accessKey).keyboard(style: .code)
      TextField("Secret Key", text: $secretKey).keyboard(style: .code)
      CreationButtons(settings: settings)
    }
    private var isReady: Bool {
      !bucketName.isEmpty && !endpoint.isEmpty && !accessKey.isEmpty && !secretKey.isEmpty
    }
    private var settings: Hub.Launcher.AppSettings? {
      return isReady ? .s3(access: accessKey, secret: secretKey, region: region, endpoint: endpoint, bucket: bucketName) : nil
    }
  }
  struct CreationButtons: View {
    @Environment(Installer.self) private var installer
    let settings: Hub.Launcher.AppSettings?
    @State var testSucccessful: Bool?
    var body: some View {
      HStack {
        if installer.permission != nil {
          AsyncButton("Allow Access") {
            try await installer.allow()
          }
        } else if installer.storageInstalled {
          AsyncButton("Test") {
            testSucccessful = nil
            testSucccessful = try await installer.test()
          }
        }
        AsyncButton(installer.storageInstalled ? "Update" : "Create") {
          if let settings {
            try await installer.set(settings: settings)
          }
        }
        if let testSucccessful {
          Image(systemName: testSucccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(testSucccessful ? .green : .red)
        }
      }.buttonStyle(.borderedProminent).disabled(settings == nil)
    }
  }
  @Observable class Installer {
    var hub: Hub?
    var listenTasks = [Task<Void, Error>]() {
      didSet { oldValue.forEach { $0.cancel() } }
    }
    var storageInstalled = false
    var serviceAvailable = false
    var permission: PendingList.Item?
    static var s3: String { "S3 Storage" }
    @MainActor
    func set(hub: Hub) {
      guard self.hub !== hub else { return }
      self.hub = hub
      listenTasks = [
        Task {
          for try await apps: Hub.Launcher.Apps in hub.client.values("launcher/info") {
            storageInstalled = apps.apps.contains(where: { $0.name == Installer.s3 })
          }
        },
        Task {
          for try await status: Status in hub.client.values("hub/status") {
            serviceAvailable = status.services.contains(where: { $0.name.starts(with: Installer.s3) })
          }
        },
        Task {
          for try await permissions: PendingList in hub.client.values("hub/host/pending") {
            permission = permissions.list.last(where: { $0.pending.contains(where: { $0.starts(with: "s3/") }) })
          }
        },
      ]
    }
    func set(settings: Hub.Launcher.AppSettings) async throws {
      try await hub?.launcher.setupS3(id: Installer.s3, update: storageInstalled, settings: settings)
    }
    func allow() async throws {
      guard let permission, let hub else { return }
      try await hub.host.allow(key: permission.id, paths: permission.pending)
      self.permission = nil
    }
    func test() async throws -> Bool {
      guard let hub else { return false }
      do {
        try await hub.client.send("s3/list")
        return true
      } catch {
        return false
      }
    }
  }
}

extension Data {
  static func random(_ length: Int) -> Data {
    var data = Data(repeating: 0, count: length)
    _ = data.withUnsafeMutableBytes { (pointer: UnsafeMutableRawBufferPointer) in
      SecRandomCopyBytes(kSecRandomDefault, length, pointer.baseAddress!)
    }
    return data
  }
}
extension String {
  static func random() -> String {
    Data.random(32).base64EncodedString().replacingOccurrences(of: "+", with: "")
      .replacingOccurrences(of: "/", with: "")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension Hub.Launcher.AppSettings {
  static func s3(access: String, secret: String, region: String, endpoint: String, bucket: String) -> Self {
    var data: [String: String] = [
      "S3_ACCESS_KEY_ID": access,
      "S3_ENDPOINT": endpoint,
      "S3_BUCKET": bucket
    ]
    if !region.isEmpty {
      data["S3_REGION"] = region
    }
    return Hub.Launcher.AppSettings(env: data, secrets: [
      "S3_SECRET_ACCESS_KEY": secret
    ])
  }
}
extension Hub.Launcher {
  @MainActor
  func setupS3(id: String, update: Bool, settings: Hub.Launcher.AppSettings) async throws {
    if update {
      try await app(id: id).updateSettings(settings)
    } else {
      try await create(.init(name: id, active: true, restarts: true, setup: .bun(.init(repo: "v57/hub-s3", commit: nil, command: nil)), settings: settings))
    }
  }
  @MainActor
  func createLocal() async throws {
    try await create(.init(name: "Local Storage", active: true, restarts: true, setup: .bun(.init(repo: "v57/hub-s3-local", commit: nil, command: nil)), settings: nil))
  }
}

#Preview {
  InstallS3().test()
}

