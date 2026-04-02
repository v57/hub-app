//
//  UI Types.swift
//  Hub
//
//  Created by Dmitry Kozlov on 6/7/25.
//

import Foundation
import HubService

extension Element.Action {
  
  func perform(hub: Hub, app: ServiceApp, nested: NestedList?, context: Hub.Context?) async throws {
    let body = body.resolve(app: app, nested: nested)
    let result: AnyCodable = try await hub.client.send(path, body, context: context)
    result.update(app: app, nested: nested, output: output)
  }
  func perform(hub: Hub, app: ServiceApp, nested: NestedList?, context: Hub.Context?, customValues: (inout [String: AnyCodable]) -> Void) async throws {
    var body: AnyCodable? = body.resolve(app: app, nested: nested)
    switch body {
    case .dictionary(var dictionary):
      customValues(&dictionary)
      body = .dictionary(dictionary)
    default:
      var dictionary = [String: AnyCodable]()
      customValues(&dictionary)
      body = .dictionary(dictionary)
    }
    let result: AnyCodable = try await hub.client.send(path, body, context: context)
    result.update(app: app, nested: nested, output: output)
  }
}
extension Element.ActionBody {
  func resolve(app: ServiceApp, nested: NestedList?) -> AnyCodable? {
    switch self {
    case .single(let string):
      guard let string = nested?.data?[string] ?? app.data[string] else { return nil }
      return string
    case .multiple(let dictionary):
      let data = dictionary.compactMapValues { (string: String) -> AnyCodable? in
        guard let value = nested?.data?[string] ?? app.data[string] else { return nil }
        return value
      }
      return .dictionary(data)
    case .void:
      return nil
    }
  }
  func resolved() -> [String: String] {
    switch self {
    case .void: [:]
    case .single(let string): [string: string]
    case .multiple(let dictionary): dictionary
    }
  }
}

extension AnyCodable {
  func update(app: ServiceApp, nested: NestedList?, output: Element.ActionBody?) {
    let data = map(output)
    if let nested, nested.data != nil {
      nested.data?.insert(contentsOf: data)
    } else {
      app.data.insert(contentsOf: data)
    }
  }
  func map(_ output: Element.ActionBody?) -> [String: AnyCodable] {
    switch output {
    case .void, nil:
      switch self {
      case .dictionary(let dictionary): return dictionary
      default: return [:]
      }
    case .single(let key):
      return [key: self]
    case .multiple(let keys):
      guard var dictionary else { return [:] }
      for (key, value) in dictionary {
        if let mapped = keys[key] {
          dictionary[key] = nil
          dictionary[mapped] = value
        }
      }
      return dictionary
    }
  }
}

extension Dictionary {
  mutating func insert(contentsOf dictionary: Dictionary) {
    dictionary.forEach { key, value in
      self[key] = value
    }
  }
}
