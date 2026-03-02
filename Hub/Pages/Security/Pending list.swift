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
        VStack {
          Image(systemName: "shield").font(.system(size: 88))
            .gradientBlur(radius: 4)
          Text("Requests").font(.title.bold())
          Text("""
          Services can't just join your Hub without permission
          You are only allowing them to create api they ask
          If service will need to add another api, it would have to ask again
          Atm there is no way to decline requests or revoke permissions you already gave, so please be careful
          """).secondary()
            .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
      }
      ForEach(hostPending.list) { item in
        HStack {
          VStack(alignment: .leading) {
            Text(item.name)
            Text(item.id).secondary()
              .textScale(.secondary)
              .fontDesign(.monospaced)
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
  PendingListView().environment(Hub.test)
}
