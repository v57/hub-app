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
        VStack {
          Image(systemName: "wifi").font(.system(size: 88))
            .gradientBlur(radius: 4)
          Text("Connections").font(.title.bold())
          Text("""
          See all services and other devices connected to this Hub
          Assign them to permission groups
          """).secondary()
            .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
      }
      ForEach(users) { user in
        UserView(user: user, isMe: user.key == hub.key).contextMenu {
          if let key = user.key {
            Menu("Group") {
              ForEach(groups.groups) { group in
                AsyncButton(group.name) {
                  try await hub.add(key: key, group: group.name)
                }
              }
            }
          }
        }
      }
    }
  }
  struct UserView: View {
    let user: Hub.User
    let isMe: Bool
    var body: some View {
      HStack {
        IconView(icon: user.icon).frame(width: 44, height: 44)
        VStack(alignment: .leading) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            if !user.name.isEmpty {
              Text(user.name)
            }
            if let key = user.key {
              Text(isMe ? "\(key.suffix(8)) (You)" : key.suffix(8)).secondary()
                .textSelection()
            } else {
              Text("Unauthorized")
            }
          }
          if user.services > 0 || user.apps > 0 {
            HStack {
              if user.services > 0 {
                Text("\(user.services) services")
              }
              if user.apps > 0 {
                Text("\(user.apps) apps")
              }
            }.secondary()
          }
        }.lineLimit(1)
      }
    }
  }
}
#Preview {
  UserConnections().environment(Hub.test)
}
