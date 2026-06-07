//
//  Connect.swift
//  Hub
//
//  Created by Linux on 05.06.26.
//

import SwiftUI

struct ConnectView: View {
  @Environment(\.dismiss) private var dismiss
  let hubs = Hubs.main
  @State var address: String = ""
  @State var name: String = ""
  var url: URL? {
    guard var components = URLComponents(string: address) else { return nil }
    components.hub()
    guard let url = components.url else { return nil }
    guard !url.absoluteString.isEmpty else { return nil }
    return url
  }
  var providedName: String? { name.isEmpty ? url?.name : name }
  var body: some View {
    VStack(alignment: .leading) {
      if let url {
        Text(url.absoluteString)
      }
      TextField("Address", text: $address).keyboard(style: .url)
      if !address.isEmpty {
        TextField(url?.name ?? "Name", text: $name).transition(.blurReplace)
      }
      if let url, let providedName {
        Button {
          hubs.insert(with: Hub.Settings(name: providedName, address: url))
          self.name = ""
          self.address = ""
          dismiss()
        } label: {
          Text("Connect")
        }.transition(.blurReplace)
      }
    }.animation(.home, value: address.isEmpty)
      .navigationTitle("Connect")
  }
}

#Preview {
  NavigationStack {
    ConnectView()
  }
}
