//
//  User connections.swift
//  Hub
//
//  Created by Linux on 23.01.26.
//

import SwiftUI
import HubService

struct UserConnections: View {
  @Environment(Hub.self) private var hub
  @HubState(\.users) private var users
  @HubState(\.groups) private var groups
  var body: some View {
    List {
      Section {
        Placeholder(image: "wifi", title: "Connections", description: """
          See all services and other devices connected to this Hub
          Assign them to permission groups
          """) { }
      }
      ForEach($users) { $user in
        UserView(user: user, isMe: user.key == hub.key).contextMenu {
          if let key = user.key, hub.canManageGroups {
            if !groups.groups.isEmpty {
              Menu("Set Group", systemImage: "shield") {
                ForEach(groups.groups) { group in
                  AsyncButton(group.name) {
                    try await toggle(user: $user, key: key, group: group.name)
                  }
                }
              }
            }
            if let group = user.group {
              AsyncButton("Remove Group", systemImage: "xmark") {
                try await toggle(user: $user, key: key, group: group)
              }
            }
          }
        }.animation(.smooth, value: user.group)
      }
    }
  }
  func toggle(user: Binding<Hub.User>, key: String, group: String) async throws {
    if let current = user.wrappedValue.group, current == group {
      try await hub.remove(key: key, group: group)
      user.wrappedValue.group = nil
    } else {
      try await hub.add(key: key, group: group)
      user.wrappedValue.group = group
    }
  }
  struct UserView: View {
    let user: Hub.User
    let isMe: Bool
    var separator: Text { Text("•").foregroundStyle(.tertiary) }
    var body: some View {
      HStack {
        IconView(icon: user.icon).frame(width: 44, height: 44)
        VStack(alignment: .leading) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            if !user.name.isEmpty {
              Text(user.name)
            }
          }
          HStack(spacing: 4) {
            Group {
              if let group = user.group {
                Text(group).foregroundStyle(.red)
                separator
              }
              if let key = user.key {
                Text(isMe ? "\(key.suffix(8)) (You)" : key.suffix(8)).secondary()
                  .textSelection()
              } else {
                Text("Unauthorized")
              }
              if user.services > 0 {
                separator
                Text("\(user.services) services")
              }
              if user.apps > 0 {
                separator
                Text("\(user.apps) apps")
              }
            }.transition(.blurReplace)
          }.secondary()
        }.lineLimit(1)
      }
    }
  }
}
#Preview {
  UserConnections().test()
}
