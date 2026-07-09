//
//  Pending list.swift
//  Hub
//
//  Created by Linux on 07.02.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
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
#if os(tvOS)
        AsyncButton {
          try await hub.host.allow(key: item.id, paths: item.pending)
        } label: {
          HStack {
            Text(item.name)
            Text(item.id).code()
            Spacer(minLength: 0)
            Text("Allow")
          }
        }.disabled(!hub.host.canManage)
#else
        HStack {
          VStack(alignment: .leading) {
            Text(item.name)
            Text(item.id).code()
          }.lineLimit(2)
          Spacer(minLength: 0)
          if hub.host.canManage {
            AsyncButton("Allow") {
              try await hub.host.allow(key: item.id, paths: item.pending)
            }
          }
        }
#endif
      }
    }
  }
}

#Preview {
  PendingListView().test()
}
