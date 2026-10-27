//
//  Localized.swift
//  Hub
//
//  `String(localized:)` where Foundation lacks it (swift-corelibs-foundation on Linux): the key with `%@` for each
//  interpolation, looked up in the bundle's strings, else the text as written. Belongs in v57/SwiftUI's
//  SwiftUIPortability once another app needs it.
//

import Foundation

#if !canImport(Darwin)
extension String {
  struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
    /// The lookup key: the literal parts with `%@` where values go
    let key: String
    /// The values, as text
    let arguments: [String]

    init(stringLiteral value: String) {
      key = value
      arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
      key = stringInterpolation.key
      arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
      var key = ""
      var arguments: [String] = []
      init(literalCapacity: Int, interpolationCount: Int) {}
      mutating func appendLiteral(_ literal: String) {
        key += literal.replacingOccurrences(of: "%", with: "%%")
      }
      mutating func appendInterpolation<Value>(_ value: Value) {
        key += "%@"
        arguments.append(String(describing: value))
      }
    }
  }

  init(localized value: LocalizationValue, table: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {
    let format = (bundle ?? .main).localizedString(forKey: value.key, value: value.key, table: table)
    var result = ""
    var arguments = value.arguments.makeIterator()
    var rest = Substring(format)
    // Fills %@ (and %n$@) in order, unescapes %%; other specifiers stay as written
    while let percent = rest.firstIndex(of: "%") {
      result += rest[..<percent]
      let after = rest.index(after: percent)
      guard after < rest.endIndex else {
        result += "%"
        rest = rest[after...]
        break
      }
      if rest[after] == "%" {
        result += "%"
        rest = rest[rest.index(after: after)...]
      } else if rest[after] == "@" {
        result += arguments.next() ?? ""
        rest = rest[rest.index(after: after)...]
      } else {
        result += "%"
        rest = rest[after...]
      }
    }
    result += rest
    self = result
  }
}
#endif
