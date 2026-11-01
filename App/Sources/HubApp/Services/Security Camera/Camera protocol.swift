//
//  Camera protocol.swift
//  Hub
//
//  What a Hub camera's server and its viewers say to each other. The server is HTTP/1.1 on the camera device, shared
//  through Hub Network (so only devices of the Hub reach it) and behind the camera's password:
//
//      GET /                        CameraInfo (JSON)
//      GET /live                    the live stream: CameraWire records until either side closes
//      GET /snapshot.jpg?width=640  the newest picture
//      GET /events                  [CameraEvent] (JSON), newest first
//      GET /events/<id>/thumbnail.jpg, GET /events/<id>/clip.mp4
//
//  Every request carries `Authorization: Bearer <password>`.
//
//  Why a framed H.264 stream over one HTTP response, not HLS or fragmented MP4: HLS waits for whole segments (seconds
//  of latency even with 1 s segments, more with the player's buffer), while these records are the encoder's access
//  units as they come out, shown at once with AVSampleBufferDisplayLayer: the latency is the network's. It's one TCP
//  connection through the WireGuard overlay (no UDP or multicast to forward), the server drops frames for a viewer that
//  falls behind instead of queueing them, and the same access units feed a HomeKit bridge's RTP stream later. Recorded
//  clips are fragmented MP4 instead, which players and HomeKit Secure Video take.
//

import Foundation
#if canImport(PlatformCamera)
import PlatformCamera

/// The live stream's records: `[UInt32 length][UInt8 type][payload]`, big-endian, length counting type and payload
enum CameraWire {
  static let contentType = "application/vnd.hub.camera-h264"
  /// A record longer than this is a broken stream
  static let maximumRecord = 8 << 20

  enum Kind: UInt8 {
    /// flags (bit 0: keyframe), time (Float64), duration (Float32), width, height (UInt16), parameter set count
    /// (UInt8), each parameter set (UInt16 length + bytes), then the frame's AVCC data
    case video = 1
    /// CameraMotion as JSON
    case motion = 2
  }

  enum Message {
    case video(EncodedVideoFrame)
    case motion(CameraMotion)
  }

  static func record(_ frame: EncodedVideoFrame) -> Data {
    var payload = Data(capacity: frame.data.count + 64)
    payload.append(frame.isKeyframe ? 1 : 0)
    payload.append(bigEndian: frame.time.bitPattern)
    payload.append(bigEndian: Float32(frame.duration).bitPattern)
    payload.append(bigEndian: UInt16(clamping: frame.width))
    payload.append(bigEndian: UInt16(clamping: frame.height))
    payload.append(UInt8(clamping: frame.parameterSets.count))
    for set in frame.parameterSets.prefix(255) {
      payload.append(bigEndian: UInt16(clamping: set.count))
      payload.append(set.prefix(Int(UInt16.max)))
    }
    payload.append(frame.data)
    return record(.video, payload)
  }

  static func record(_ motion: CameraMotion) -> Data {
    record(.motion, (try? JSONEncoder.camera.encode(motion)) ?? Data())
  }

  private static func record(_ kind: Kind, _ payload: Data) -> Data {
    var data = Data(capacity: payload.count + 5)
    data.append(bigEndian: UInt32(payload.count + 1))
    data.append(kind.rawValue)
    data.append(payload)
    return data
  }

  /// Splits the bytes of a live stream into messages as they arrive; unknown record types are skipped
  struct Parser {
    private var buffer = Data()
    private(set) var isBroken = false

    mutating func append(_ data: Data) -> [Message] {
      guard !isBroken else { return [] }
      buffer.append(data)
      var messages = [Message]()
      var reader = Reader(buffer)
      while let length = reader.peekUInt32() {
        guard length >= 1, Int(length) <= maximumRecord else {
          isBroken = true
          return messages
        }
        guard reader.remaining >= 4 + Int(length) else { break }
        reader.skip(4)
        var record = Reader(reader.take(Int(length)))
        let kind = record.uint8().flatMap(Kind.init)
        switch kind {
        case .video:
          if let frame = Self.frame(&record) { messages.append(.video(frame)) }
        case .motion:
          if let motion = try? JSONDecoder.camera.decode(CameraMotion.self, from: record.rest) { messages.append(.motion(motion)) }
        case nil:
          break
        }
      }
      buffer = Data(reader.rest)
      return messages
    }

    private static func frame(_ reader: inout Reader) -> EncodedVideoFrame? {
      guard let flags = reader.uint8(), let time = reader.uint64(), let duration = reader.uint32(),
        let width = reader.uint16(), let height = reader.uint16(), let count = reader.uint8()
      else { return nil }
      var sets = [Data]()
      for _ in 0..<count {
        guard let length = reader.uint16(), reader.remaining >= Int(length) else { return nil }
        sets.append(Data(reader.take(Int(length))))
      }
      return EncodedVideoFrame(
        data: Data(reader.rest), isKeyframe: flags & 1 == 1, time: Double(bitPattern: time),
        duration: Double(Float32(bitPattern: duration)), parameterSets: sets, width: Int(width), height: Int(height))
    }
  }

  /// Reads big-endian integers off the front of some bytes
  private struct Reader {
    private let data: Data
    private var offset: Data.Index
    init(_ data: Data) {
      self.data = data
      offset = data.startIndex
    }
    var remaining: Int { data.endIndex - offset }
    var rest: Data { data[offset...] }
    func peekUInt32() -> UInt32? {
      guard remaining >= 4 else { return nil }
      return data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    mutating func skip(_ count: Int) { offset += count }
    mutating func take(_ count: Int) -> Data {
      defer { offset += count }
      return data[offset..<offset + count]
    }
    private mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
      let size = MemoryLayout<T>.size
      guard remaining >= size else { return nil }
      return take(size).reduce(T.zero) { $0 << 8 | T($1) }
    }
    mutating func uint8() -> UInt8? { integer(UInt8.self) }
    mutating func uint16() -> UInt16? { integer(UInt16.self) }
    mutating func uint32() -> UInt32? { integer(UInt32.self) }
    mutating func uint64() -> UInt64? { integer(UInt64.self) }
  }
}

private extension Data {
  mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
#endif

/// The camera's state on the live stream and in `CameraInfo`
struct CameraMotion: Codable, Hashable, Sendable {
  /// Motion is going on, and a clip is being recorded
  var isActive: Bool
  /// How much of the picture moves, 0…1
  var level: Double
}

/// What `GET /` answers
struct CameraInfo: Codable, Hashable, Sendable {
  /// The camera device's name
  var name: String
  /// Which of its cameras
  var camera: String
  var width: Int
  var height: Int
  var fps: Int
  var motion: CameraMotion
  var sensitivity: Double
  /// Where clips go: `device` or `hub`
  var storage: String
}

/// A motion event and its clip
struct CameraEvent: Codable, Hashable, Identifiable, Sendable {
  var id: String
  var start: Date
  /// Nil while it's still recording
  var end: Date?
  /// The most of the picture that moved, 0…1
  var peak: Double
  /// Bytes of the clip; 0 while recording
  var size: Int
  /// Where the clip is: `device` (in the camera's clips folder) or `hub` (an S3 key on the hub's storage)
  var storage: String
  /// The clip's file name (device) or key (hub)
  var clip: String?
  var duration: Double { (end ?? Date()).timeIntervalSince(start) }
}

extension JSONEncoder {
  static let camera: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
}

extension JSONDecoder {
  static let camera: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
