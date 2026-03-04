//
//  Pending list.swift
//  Hub
//
//  Created by Linux on 07.02.26.
//

import SwiftUI
import HubService

struct PendingListView: View {
  @Environment(Hub.self) private var hub
  @HubState(\.hostPending) private var hostPending
  var body: some View {
    List {
      Section {
        Placeholder(image: "shield", title: "Requests", description: """
          Services can't just join your Hub without permission
          You are only allowing them to create api they ask
          If service will need to add another api, it would have to ask again
          Atm there is no way to decline requests or revoke permissions you already gave, so please be careful
          """) { }
      }
      ForEach(hostPending.list) { item in
        HStack {
          VStack(alignment: .leading) {
            Text(item.name)
            Text(item.id).code()
          }.lineLimit(2)
          Spacer()
          if hub.host.canManage {
            AsyncButton("Allow") {
              try await hub.host.allow(key: item.id, paths: item.pending)
            }
          }
        }
      }
    }
  }
}

#Preview {
  PendingListView().test()
}
