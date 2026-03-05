//
//  Permission groups.swift
//  Hub
//
//  Created by Linux on 16.11.25.
//

import SwiftUI

struct PermissionGroups: View {
  @Environment(Hub.self) var hub
  @State var adding = false
  @State var name: String = ""
  @HubState(\.permissions) private var permissions
  @HubState(\.groups) private var groups
  @State var selected = Set<String>()
  @State var editing: String?
  var body: some View {
    let showsPlaceholder = !adding && groups.groups.isEmpty
    ScrollView {
      VStack {
        if adding {
          addGroupsView
        } else {
          groupsView
        }
      }.frame(maxWidth: .infinity).safeAreaPadding(.horizontal)
    }.lineLimit(2).overlay {
      VStack {
        if showsPlaceholder {
          Placeholder(image: "shield", title: "Permission Groups", description: "Secure your Hub") {
            Label("Add Owners", systemImage: "key")
              .foregroundStyle(.red.gradient, .primary)
            Label("Create Groups", systemImage: "plus")
              .foregroundStyle(.blue, .primary)
          }
        }
      }.animation(.smooth, value: showsPlaceholder)
    }.safeAreaInset(edge: .bottom) {
      if hub.require(permissions: "hub/group/update") {
        HStack {
          if adding {
            TextField("Name", text: $name.animation()).frame(maxWidth: 150)
              .transition(.blurReplace)
          }
          AsyncButton(createTitle) {
            if adding && !name.isEmpty {
              try await hub.client.send("hub/group/update", UpdateGroup(group: name, set: Array(selected)))
            }
            name = ""
            withAnimation {
              adding.toggle()
            }
          }.buttonStyle(TabButtonStyle(selected: false))
            .contentTransition(.numericText())
        }.padding()
      }
    }
  }
  var groupsView: some View {
    ForEach($groups.groups) { $group in
      let isEditing = group.name == editing
      LazyVStack(alignment: .leading, pinnedViews: .sectionHeaders) {
        Section {
          ForEach(permissions.sections) { section in
            let isSelected = $group.permissions.toggle(section.permissions.map { "\(section.name)/\($0)" })
            if isEditing || isSelected.wrappedValue {
              HStack {
                if isEditing {
                  Toggle(section.name, isOn: isSelected)
                }
                Text(section.name).fontWeight(.semibold)
              }
              ForEach(section.permissions, id: \.self) { (name: String) in
                let isSelected = $group.permissions.toggle("\(section.name)/\(name)")
                if isEditing || isSelected.wrappedValue {
                  HStack {
                    if isEditing {
                      Toggle(name, isOn: isSelected)
                    }
                    Text(name).font(isEditing ? .body : .caption)
                  }.padding(.leading, isEditing ? nil : 0)
                }
              }
            }
          }
        } header: {
          HStack {
            Text(group.name).font(.title)
            if isEditing {
              AsyncButton("Delete Group", role: .destructive) {
                try await hub.client.send("hub/group/remove", group.name)
                withAnimation {
                  editing = nil
                }
              }
            }
            Spacer()
            if isEditing {
              AsyncButton("Save") {
                try await hub.client.send("hub/group/update", UpdateGroup(group: group.name, set: Array(group.permissions)))
                withAnimation {
                  editing = nil
                }
              }
            } else {
              Button("Edit") {
                withAnimation {
                  editing = group.name
                }
              }
            }
          }
        }.labelsHidden()
      }
    }
  }
  var addGroupsView: some View {
    LazyVStack(alignment: .leading, pinnedViews: .sectionHeaders) {
      ForEach(permissions.sections) { section in
        Section {
          ForEach(section.permissions, id: \.self) { (name: String) in
            Toggle(name, isOn: $selected.toggle("\(section.name)/\(name)"))
              .padding(.leading)
          }
        } header: {
          Toggle(section.name, isOn: $selected.toggle(section.permissions.map { "\(section.name)/\($0)" }))
            .fontWeight(.semibold)
        }
      }
    }
  }
  var createTitle: LocalizedStringKey {
    adding ? name.isEmpty ? "Cancel" : "Create" : "Create group"
  }
  struct UpdateGroup: Encodable {
    let group: String
    let set: [String]
  }
}

typealias RawPermissionList = [String: [String: [String]]]
struct PermissionList: Decodable {
  var sections: [Section]
  init() {
    sections = []
  }
  init(from decoder: any Decoder) throws {
    let names = try decoder.singleValueContainer()
      .decode([String: String].self)
    var data = [String: Set<String>]()
    names.forEach { path, name in
      let split = name.components(separatedBy: ": ")
      let parent: String
      let permission: String
      if split.count == 1 {
        parent = "Other"
        permission = name
      } else {
        parent = split[0]
        permission = split[1...].joined(separator: ": ")
      }
      var array = data[parent] ?? []
      array.insert(permission)
      data[parent] = array
    }
    sections = data.map { name, permissions in
      Section(name: name, permissions: permissions.sorted())
    }.sorted(by: { $0.name < $1.name })
  }
  struct Section: Identifiable {
    var id: String { name }
    var name: String
    var permissions: [String]
    func visible(selected: Set<String>, isEditing: Bool) -> [String] {
      if isEditing {
        permissions
      } else {
        permissions.filter(selected.contains)
      }
    }
  }
}
struct GroupList: Decodable {
  var groups: [Group]
  init() {
    groups = []
  }
  init(from decoder: any Decoder) throws {
    groups = try decoder.singleValueContainer()
      .decode([String: Set<String>].self)
      .map { Group(name: $0.key, permissions: $0.value) }
      .sorted(by: { $0.name < $1.name })
  }
  struct Group: Identifiable {
    var id: String { name }
    let name: String
    var permissions: Set<String>
  }
}

extension Binding where Value: SetAlgebra & Sendable {
  func toggle(_ key: Value.Element) -> Binding<Bool> {
    Binding<Bool> {
      wrappedValue.contains(key)
    } set: { newValue in
      if newValue {
        wrappedValue.insert(key)
      } else {
        wrappedValue.remove(key)
      }
    }
  }
  func toggle(_ keys: [Value.Element]) -> Binding<Bool> {
    Binding<Bool> {
      !keys.contains { !wrappedValue.contains($0) }
    } set: { newValue in
      if newValue {
        for key in keys {
          wrappedValue.insert(key)
        }
      } else {
        for key in keys {
          wrappedValue.remove(key)
        }
      }
    }
  }
}

#Preview {
  PermissionGroups().test()
}
