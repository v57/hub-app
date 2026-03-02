//
//  Services.swift
//  Hub
//
//  Created by Dmitry Kozlov on 16/2/25.
//

import SwiftUI
import HubService

extension String {
  func copyToClipboard() {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(self, forType: .string)
    #elseif os(iOS) || os(watchOS)
    UIPasteboard.general.string = self
    #endif
  }
}

struct Services: View {
  @Environment(Hub.self) var hub
  @HubState(\.status) var status
  var body: some View {
    List {
      Section {
        VStack {
          Image(systemName: "hexagon").font(.system(size: 88))
            .gradientBlur(radius: 4)
          Text("Hub Api").font(.title.bold())
          Text("""
          Api produced by Services of this Hub located here
          You can change load balancer settings for each api here
          See number of total, pending and currently processing requests
          """).secondary()
            .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
      }
      ForEach(status.services, id: \.name) { service in
        Service(service: service)
      }
    }.navigationTitle(hub.isConnected ? "\(status.requests) requests" : "Disconnected").toolbar {
      Button("Copy Key", systemImage: "key.fill") {
        KeyChain.main.publicKey().copyToClipboard()
      }
    }
  }
  struct PermissionView: View {
    let permission: String
    var body: some View {
      switch permission {
      case "owner":
        Button {
          
        } label: {
          Image(systemName: "macbook.badge.shield.checkmark")
        }.accessibilityHint("Owner")
      default:
        Text(permission.prefix(8)).padding(.horizontal)
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
    }.contextMenu {
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
  Services()
    .environment(Hub.test)
}
