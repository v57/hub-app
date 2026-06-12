//
//  Lockdown.swift
//  Hub
//
//  Created by Linux on 25.02.26.
//

import SwiftUI
import Combine
import HubService

extension View {
  @ViewBuilder
  func toggleSwitch() -> some View {
#if os(tvOS)
    if #available(tvOS 18.0, *) {
      toggleStyle(.switch)
    } else {
      self
    }
#else
    toggleStyle(.switch)
#endif
  }
}

struct LockdownView: View {
  @Environment(Hub.self) private var hub
  @HubState(\.users) private var users
  @HubState(\.groups) private var groups
  @HubState(\.whitelist) private var whitelist
  var body: some View {
    List {
      Section {
        LockdownStatus()
      }.listRowBackground(Color.clear)
      ForEach(users) { user in
        UserView(user: user, isMe: user.key == hub.key, whitelist: whitelist).contextMenu {
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
    }.contentTransition(.numericText())
  }
  struct LockdownStatus: View {
    @Environment(Hub.self) private var hub
    @HubState(\.whitelist) private var whitelist
    @State private var isEnabled = false
    @State private var toggleTask: AnyCancellable?
    var body: some View {
      Placeholder(image: "key.shield.fill", title: "Lockdown Mode", description: "Maximum Security", isEnabled: isEnabled) {
        Text("""
          Block any untrusted device or service from accessing your hub
          You will still be able to add keys in lockdown mode
          Every untrusted service will not connect to your hub anymore
          """).multilineTextAlignment(.center)
        Toggle("Lockdown", isOn: $isEnabled.animation(.spring(response: 1, dampingFraction: 0.5)))
          .toggleSwitch().labelsHidden()
      }.task(id: whitelist.enabled) {
        isEnabled = whitelist.enabled
      }.onChange(of: isEnabled) { toggle() }
    }
    func toggle() {
      let task = Task {
        try await hub.lockdown(SetLockdown(enabled: isEnabled))
      }
      toggleTask = AnyCancellable { task.cancel() }
    }
  }
  struct UserView: View {
    @Environment(Hub.self) private var hub
    let user: Hub.User
    let isMe: Bool
    let whitelist: WhitelistStatus
    var body: some View {
      let isTrusted = if let key = user.key {
        whitelist.users.contains(key)
      } else {
        false
      }
      HStack {
        IconView(icon: user.icon).frame(width: 44, height: 44)
        VStack(alignment: .leading) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            if isTrusted {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue)
                .fontWeight(.bold)
                .transition(.scale)
            }
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
        Spacer(minLength: 0)
        if let key = user.key {
          AsyncButton {
            if isTrusted {
              try await hub.lockdown(SetLockdown(remove: [key]))
            } else {
              try await hub.lockdown(SetLockdown(add: [key]))
            }
          } label: {
            Text(isTrusted ? "Trusted" : "Trust")
          }.buttonStyle(ActionButtonStyle(enabled: isTrusted))
        }
      }
    }
  }
  struct ActionButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    let enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .foregroundStyle(enabled ? Color.secondary : Color.white)
        .padding(.horizontal, 12 * interfaceScale)
        .padding(.vertical, 4 * interfaceScale)
        .background(enabled ? Color.tertiaryBackground : Color.blue, in: .capsule)
        .scaleEffect(configuration.isPressed ? 1.2 : isFocused ? 1.1 : 1.0)
        .animation(.bouncy, value: isFocused).animation(.smooth(duration: 0.25), value: configuration.isPressed)
    }
  }
}

#Preview {
  LockdownView().test()
}
