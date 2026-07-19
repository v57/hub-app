//
//  Services.swift
//  Hub
//
//  Created by Dmitry Kozlov on 16/2/25.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
import HubService

struct Services: View {
  @Environment(Hub.self) var hub
  @HubState(\.status) var status
  @State var selected: String?
  var compressed: [CompressedService] {
    var dictionary = [String: CompressedService]()
    for service in status.services {
      let id = String(service.name.split(separator: "/")[0])
      var data = dictionary[id] ?? CompressedService(id: id)
      data.add(service: service)
      dictionary[id] = data
    }
    return dictionary.values.sorted(by: { $0.id < $1.id })
  }
  struct CompressedService: Identifiable {
    var id: String
    var services: Int = 0
    var disabled: Int = 0
    var requests: Int = 0
    var pending: Int = 0
    var running: Int = 0
    mutating func add(service: Status.Service) {
      services += service.services
      disabled += service.disabled ?? 0
      requests += service.requests
      pending += service.pending ?? 0
      running += service.running ?? 0
    }
  }
  var body: some View {
    ScrollView {
      VStack {
        Placeholder(image: "hexagon", title: "Hub API", description: """
        Api produced by Services of this Hub located here
        You can change load balancer settings for each api here
        See number of total, pending and currently processing requests
        """) { }
        if let selected {
          Button(selected.dropLast(1), systemImage: "chevron.left") {
            self.selected = nil
          }.frame(maxWidth: .infinity, alignment: .leading)
          LazyVGrid(columns: [.init(.adaptive(minimum: 120))]) {
            ForEach(status.services.filter { $0.name.starts(with: selected) }, id: \.name) { service in
              Service(service: service)
            }
          }
        } else {
          LazyVGrid(columns: [.init(.adaptive(minimum: 120))]) {
            ForEach(compressed) { service in
              Button {
                selected = service.id + "/"
              } label: {
                CompressedServiceView(service: service)
              }.buttonStyle(.environment)
            }
          }
        }
      }.padding(4)
    }.navigationTitle(hub.isConnected ? "\(status.requests) requests" : "Disconnected").toolbar {
      Button("Copy Key", systemImage: "key.fill") {
        KeyChain.main.publicKey().copyToClipboard()
      }
    }
  }
  struct CompressedServiceView: View {
    typealias Balancer = Status.BalancerType
    @Environment(Hub.self) private var hub
    let service: CompressedService
    var onlineStatus: OnlineStatus {
      if service.services > 0 {
        OnlineStatus.online
      } else if service.disabled > 0 {
        OnlineStatus.unauthorized
      } else {
        OnlineStatus.offline
      }
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(service.id)
          onlineStatus.view
        }
        HStack {
          if service.requests > 0 {
            Label("\(service.requests)", systemImage: "number")
          } else {
            Text("Never used")
          }
          if service.running > 0 {
            Label("\(service.running)", systemImage: "clock.arrow.2.circlepath")
          }
          if service.pending > 0 {
            Label("\(service.pending)", systemImage: "tray.full")
          }
        }.secondary().labelStyle(BadgeLabelStyle())
      }.padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondaryBackground, in: .rounded(12))
    }
    struct BadgeLabelStyle: LabelStyle {
      func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
          configuration.icon
          configuration.title
        }
      }
    }
  }
}
struct Service: View {
  typealias Balancer = Status.BalancerType
  @Environment(Hub.self) private var hub
  let service: Status.Service
  var onlineStatus: OnlineStatus {
    if service.services > 0 {
      OnlineStatus.online
    } else if (service.disabled ?? 0) > 0 {
      OnlineStatus.unauthorized
    } else {
      OnlineStatus.offline
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(service.name)
        onlineStatus.view
      }
      HStack {
        if service.requests > 0 {
          Label("\(service.requests)", systemImage: "number")
        }
        if service.balancerType != .counter {
          Image(systemName: service.balancerType.icon).secondary()
        }
        if let running = service.running, running > 0 {
          Label("\(running)", systemImage: "clock.arrow.2.circlepath")
        }
        if let pending = service.pending, pending > 0 {
          Label("\(pending)", systemImage: "tray.full")
        }
      }.secondary().labelStyle(BadgeLabelStyle())
    }.padding(.horizontal, 12).padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.secondaryBackground, in: .rounded(12))
      .contextMenu {
        Section("Load balancer") {
          ForEach(Balancer.all, id: \.rawValue) { balancer in
            AsyncButton(balancer.name, systemImage: balancer.icon) {
              try await update(balancer: balancer)
            }
          }
        }
      }
  }
  func update(balancer: Balancer) async throws {
    try await hub.client.send("hub/balancer/set", UpdateBalancer(path: service.name, type: balancer.rawValue))
  }
  private struct UpdateBalancer: Codable {
    let path: String
    let type: String
  }
  struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
      HStack(spacing: 4) {
        configuration.icon
        configuration.title
      }
    }
  }
}

extension Status.BalancerType {
  var icon: String {
    switch self {
    case .random: "dice"
    case .counter: "arrow.triangle.2.circlepath"
    case .first: "line.3.horizontal.decrease"
    case .available: "arrow.clockwise.circle"
    case .unknown: "Unknown"
    }
  }
  var name: LocalizedStringKey {
    switch self {
    case .random: "Random"
    case .counter: "Round-robin"
    case .first: "Queued Non Distributed"
    case .available: "Queued Distributed"
    case .unknown: "Unknown"
    }
  }
}

enum OnlineStatus: Comparable {
  case online, unauthorized, offline
  @MainActor
  var view: some View {
    Circle().fill(background.opacity(1)).frame(width: 6)
  }
  var background: Color {
    switch self {
    case .online: .blue
    case .offline: .red
    case .unauthorized: .orange
    }
  }
}

#Preview {
  Services().test()
}
