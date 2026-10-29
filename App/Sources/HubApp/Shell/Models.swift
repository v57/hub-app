//
//  Models.swift
//  Hub
//
//  What a hub sends, read for its pages: permission groups and the permissions they grant, and how a device shows.
//

import Foundation
import HubService

/// `hub/group/names`: each permission's path by its name, in sections ("Files: Read files" is Read files in Files)
struct PermissionList: Decodable {
  var sections: [Section]
  init() {
    sections = []
  }
  init(from decoder: any Decoder) throws {
    let names = try decoder.singleValueContainer()
      .decode([String: String].self)
    var data = [String: Set<String>]()
    var paths = [String: [String: String]]()
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
      paths[parent, default: [:]][permission] = path
    }
    sections = data.map { name, permissions in
      Section(name: name, permissions: permissions.sorted(), pathsByName: paths[name] ?? [:])
    }.sorted(by: { $0.name < $1.name })
  }
  struct Section: Identifiable {
    var id: String { name }
    var name: String
    var permissions: [String]
    /// The API path of each permission, by its name
    var pathsByName: [String: String] = [:]
  }
}

/// `hub/group/list`: each group and the permission paths it grants
struct GroupList: Decodable {
  var groups: [Group]
  init() {
    groups = []
  }
  init(from decoder: any Decoder) throws {
    groups = try decoder.singleValueContainer()
      .decode([String: Set<String>].self)
      .map { Group(name: $0.key, permissions: $0.value) }
      // Owners first, then by name
      .sorted(by: { ($0.name == "owners" ? 0 : 1, $0.name) < ($1.name == "owners" ? 0 : 1, $1.name) })
  }
  struct Group: Identifiable {
    var id: String { name }
    let name: String
    var permissions: Set<String>
  }
}

extension Device {
  static func symbol(platform: String?) -> String {
    switch platform {
    case "macos": "macbook"
    case "ios": "iphone"
    case "ipados": "ipad"
    case "visionos": "visionpro"
    case "tvos": "appletv"
    case "watchos": "applewatch"
    case "linux": "server.rack"
    case "windows": "pc"
    case "android": "smartphone"
    default: "desktopcomputer"
    }
  }
  var statusText: String {
    if revoked { return String(localized: "Revoked") }
    if !approved { return String(localized: "Waiting for approval") }
    if online { return String(localized: "Online") }
    if let lastSeen { return String(localized: "Last seen \(lastSeen.formatted(.relative(presentation: .named)))") }
    return String(localized: "Offline")
  }
}

extension Date {
  /// How long ago, short: now, 12m, 3h
  var shortRelative: String {
    let offset = -Int(timeIntervalSinceNow) / 60
    guard offset > -1 else { return "future" }
    guard offset > 1 else { return "now" }
    guard offset > 60 else { return "\(offset)m" }
    return "\(offset / 60)h"
  }
}
