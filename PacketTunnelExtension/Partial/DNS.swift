import Foundation
import Network

enum DNS {
/// Authoritative DNS view for names granted to the active Hub Network profile.
///
/// Callers must replace this view whenever Hub permission or provider state
/// changes. Names under `hub.invalid` that are absent from the view fail closed
/// with NXDOMAIN. Queries outside the reserved suffix return `nil` so they can
/// continue through the system's ordinary resolver.
  struct Resolver {
    static let suffix = "hub.invalid"
    static let virtualServerIPv4 = "100.127.255.53"
    static let answerTTL: UInt32 = 30
    
    private let records: [String: Record.Resolved]
    
    init(records: [Record]) throws {
      var indexed: [String: Record.Resolved] = [:]
      for record in records {
        let record = try Record.Resolved(authority: record.authority, address: record.address)
        guard indexed.updateValue(record, forKey: record.authority) == nil else {
          throw Error.dupe(record.authority)
        }
      }
      self.records = indexed
    }
    
    /// Returns an authoritative DNS response, or `nil` for non-Hub DNS.
    ///
    /// Malformed packets and unsupported DNS operations return `nil`; caller
    /// should drop them. Reserved A/AAAA questions always receive a response:
    /// NOERROR with matching records, or NXDOMAIN when authority is not present.
    func response(to query: Data) -> Data? {
      guard query.count >= 12 else { return nil }
      let bytes = [UInt8](query)
      var response = Response(query: bytes)
      let flags = bytes.uint16(at: 2)
      let questionCount = bytes.uint16(at: 4)
      guard flags & 0x8000 == 0, flags & 0x7800 == 0, questionCount == 1 else { return nil }
      
      guard let decoded = bytes.name(from: 12), decoded.nextOffset + 4 <= bytes.count else { return nil }
      let name = Record.Resolved.canonicalName(decoded.name)
      guard Record.Resolved.isReservedName(name) else { return nil }
      
      let queryType = bytes.uint16(at: decoded.nextOffset)
      let queryClass = bytes.uint16(at: decoded.nextOffset + 2)
      response.questionEnd = decoded.nextOffset + 4
      
      guard queryClass == 1 else { return response.respond(code: 4) }
      guard let record = records[name] else { return response.respond(code: 3) }
      
      if queryType == 1 || queryType == 28 {
        switch (queryType, record.address) {
        case (1, .ipv4(let address)): response.answers.append((1, Array(address.rawValue)))
        case (28, .ipv6(let address)): response.answers.append((28, Array(address.rawValue)))
        default: break
        }
        return response.respond(code: 0)
      } else {
        return response.respond(code: 4)
      }
    }
    
    struct Response {
      let query: [UInt8]
      var questionEnd = 0
      var answers: [(type: UInt16, address: [UInt8])] = []
      func respond(code: UInt16) -> Data {
        var result = Array(query[0..<questionEnd])
        let queryFlags = query.uint16(at: 2)
        // Response, authoritative, preserve RD, no recursion advertised.
        result.write(0x8400 | (queryFlags & 0x0100) | code, at: 2)
        result.write(UInt16(answers.count), at: 6)
        result.write(0 as UInt16, at: 8)
        result.write(0 as UInt16, at: 10)
        
        for answer in answers {
          result.append(contentsOf: [0xc0, 0x0c])
          result.append(answer.type)
          result.append(1 as UInt16)
          result.append(Resolver.answerTTL)
          result.append(UInt16(answer.address.count))
          result.append(contentsOf: answer.address)
        }
        return Data(result)
      }
    }
  }
  struct Record: Decodable {
    let authority: String
    let address: String
    
    struct Resolved: Equatable, Sendable {
      let authority: String
      let address: Address

      init(authority: String, address: String) throws {
        self.address = try Address(address)
        let canonicalAuthority = Resolved.canonicalName(authority)
        guard Resolved.isReservedName(canonicalAuthority) && canonicalAuthority != Resolver.suffix && Resolved.isValidDNSName(canonicalAuthority) else {
          throw Error.authority(authority)
        }
        self.authority = canonicalAuthority
      }

      fileprivate static func canonicalName(_ name: String) -> String {
        guard let index = name.lastIndex(where: { $0 != "." }) else { return "" }
        return name[...index].lowercased()
      }

      fileprivate static func isReservedName(_ name: String) -> Bool {
        name == Resolver.suffix || name.hasSuffix(".\(Resolver.suffix)")
      }

      private static func isValidDNSName(_ name: String) -> Bool {
        guard name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false)
          .allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
              return false
            }
            return label.unicodeScalars.allSatisfy {
              $0.isASCII && (
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
              )
            }
          }
      }
    }
  }
  enum Error: Swift.Error, Equatable {
    case authority(String), address(String), overlay(String), prefix(String), dupe(String)
  }
}

extension String {
  func address() throws -> Address {
    try Address(self)
  }
  func overlayAddress() throws -> Address {
    try Address(overlay: self)
  }
}

enum Address: Equatable {
  case ipv4(IPv4Address), ipv6(IPv6Address)
  var host: NWEndpoint.Host {
    switch self {
    case .ipv4(let address): .ipv4(address)
    case .ipv6(let address): .ipv6(address)
    }
  }
  var string: String {
    switch self {
    case .ipv4(let address): address.debugDescription // safe stuff, trust me bro
    case .ipv6(let address): address.debugDescription
    }
  }
  var prefix: Int {
    switch self {
    case .ipv4: 32
    case .ipv6: 128
    }
  }
  init(_ address: String) throws(DNS.Error) {
    if let parsed = IPv6Address(address) {
      guard parsed.rawValue.starts(with: [0xfd, 0x48, 0x55, 0x42, 0x4e, 0x45]) else { throw DNS.Error.address(address) }
      self = .ipv6(parsed)
    } else if let parsed = IPv4Address(address) {
      let bytes = Array(parsed.rawValue)
      guard bytes[0] == 100 && (bytes[1] & 0b1110_0000) == 96 else { throw DNS.Error.address(address) }
      self = .ipv4(parsed)
    } else {
      throw DNS.Error.address(address)
    }
  }
  init(overlay value: String) throws(DNS.Error) {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = Int(parts[1]) else { throw DNS.Error.overlay(value) }
    try self.init(String(parts[0]))
    guard self.prefix == prefix else { throw DNS.Error.prefix(value) }
  }
}

private extension Array where Element == UInt8 {
  func name(from start: Int) -> (name: String, nextOffset: Int)? {
    var labels: [String] = []
    var offset = start
    var nextOffset: Int?
    var visited: Set<Int> = []

    while offset < self.count {
      guard visited.insert(offset).inserted else { return nil }
      let length = Int(self[offset])
      if length == 0 {
        return (labels.joined(separator: "."), nextOffset ?? offset + 1)
      }
      if length & 0xc0 == 0xc0 {
        guard offset + 1 < self.count else { return nil }
        let pointer = ((length & 0x3f) << 8) | Int(self[offset + 1])
        guard pointer < self.count else { return nil }
        if nextOffset == nil { nextOffset = offset + 2 }
        offset = pointer
        continue
      }
      guard length <= 63, offset + 1 + length <= self.count,
            let label = String(bytes: self[(offset + 1)..<(offset + 1 + length)], encoding: .utf8),
            label.unicodeScalars.allSatisfy({ $0.isASCII }) else {
        return nil
      }
      labels.append(label)
      offset += 1 + length
    }
    return nil
  }

  func uint16(at offset: Int) -> UInt16 {
    UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
  }

  mutating func write(_ value: UInt16, at offset: Int) {
    self[offset] = UInt8(value >> 8)
    self[offset + 1] = UInt8(value & 0xff)
  }

  mutating func append(_ value: UInt16) {
    append(UInt8(value >> 8))
    append(UInt8(value & 0xff))
  }

  mutating func append(_ value: UInt32) {
    append(UInt8((value >> 24) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

}
