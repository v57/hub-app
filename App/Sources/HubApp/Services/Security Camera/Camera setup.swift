//
//  Camera setup.swift
//  Hub
//
//  One of this device's cameras as a Hub camera: which lens, the place it watches (its name on the hub), its video,
//  where motion counts and how sensitive it is, and how much it adjusts its picture. Each one turned on is its own
//  camera on the hub: its own share, password, server and clips.
//

#if canImport(PlatformCamera)
import Foundation
import PlatformCamera
import PlatformPower

struct CameraSetup: Codable, Hashable, Identifiable, Sendable {
  var id: String
  /// A `CameraDevice.id`
  var device: String
  /// The place it watches: its name on the hub (Front Door)
  var place: String
  var isOn: Bool
  var video = CameraVideo()
  var sensitivity = 0.5
  /// Where motion counts; nil for the whole picture
  var zone: MotionDetector.Zone?
  var picture = CameraProfile.balanced.picture(stabilizes: false)
  /// What Lock Now froze, while focus, exposure or white balance stay locked there
  var locked: CameraLockedValues?
  /// When it records clips (a Mac's camera; iPhone and iPad always record)
  var recording = CameraRecording()

  init(id: String = UUID().uuidString.lowercased(), device: String, place: String, isOn: Bool) {
    self.id = id
    self.device = device
    self.place = place
    self.isOn = isOn
  }

  // Settings saved before a field existed keep its default
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    device = try container.decode(String.self, forKey: .device)
    place = try container.decode(String.self, forKey: .place)
    isOn = try container.decode(Bool.self, forKey: .isOn)
    video = try container.decodeIfPresent(CameraVideo.self, forKey: .video) ?? CameraVideo()
    sensitivity = try container.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 0.5
    zone = try container.decodeIfPresent(MotionDetector.Zone.self, forKey: .zone)
    picture = try container.decodeIfPresent(CameraPicture.self, forKey: .picture) ?? CameraProfile.balanced.picture(stabilizes: false)
    locked = try container.decodeIfPresent(CameraLockedValues.self, forKey: .locked)
    recording = try container.decodeIfPresent(CameraRecording.self, forKey: .recording) ?? CameraRecording()
  }

  /// The profile the picture and video match, if any
  var profile: CameraProfile? {
    CameraProfile.allCases.first { $0.matches(self) }
  }

  var configuration: CameraConfiguration {
    CameraConfiguration(device: device, width: video.width, height: video.height, fps: video.fps, picture: picture)
  }
}

/// How a camera's video is encoded
struct CameraVideo: Codable, Hashable, Sendable {
  /// 360, 480, 720, 1080 or 2160
  var height = 720
  var fps = 24
  var codec = VideoCodec.h264
  /// Bits per second; nil picks one from the size, frame rate and codec
  var bitrate: Int?

  static let heights = CameraCapabilities.standardSizes.map(\.1)
  static let frameRates = [10, 24, 30, 60]

  var width: Int { CameraCapabilities.standardSizes.first { $0.1 == height }?.0 ?? height * 16 / 9 }
  var suggestedBitrate: Int { VideoFormat.suggestedBitrate(width: width, height: height, fps: fps, codec: codec) }
  var effectiveBitrate: Int { bitrate ?? suggestedBitrate }
  var format: VideoFormat {
    VideoFormat(width: width, height: height, fps: fps, bitrate: effectiveBitrate, codec: codec)
  }

  var title: String { "\(height)p · \(fps) fps · \(codec.title)" }
}

/// When a camera records clips. On a Mac someone works at, motion is mostly them: When I'm Away keeps clips (and
/// motion notifications) for when the Mac is locked, asleep or has had no keyboard or mouse for `awayMinutes`. Live
/// view goes on either way, unless `liveWhilePaused` is off.
struct CameraRecording: Codable, Hashable, Sendable {
  enum When: String, Codable, CaseIterable, Sendable {
    case always
    case whenAway

    var title: String { self == .always ? "Always" : "When I’m Away" }
  }

  var when: When = UserPresence.isSupported ? .whenAway : .always
  var awayMinutes = 5
  var liveWhilePaused = true

  static let minuteChoices = [1, 2, 5, 10, 15, 30]
}

/// Presets for picture and power: how much the camera adjusts its picture, against heat and battery
enum CameraProfile: String, Codable, CaseIterable, Sendable {
  case bestPicture, balanced, lowPower

  var title: String {
    switch self {
    case .bestPicture: "Best Picture"
    case .balanced: "Balanced"
    case .lowPower: "Low Power"
    }
  }

  var help: String {
    switch self {
    case .bestPicture: "Stabilization on where the camera has it; focus, exposure and colour adjust all the time."
    case .balanced: "Exposure and colour adjust every 10 s, not every frame."
    case .lowPower: "No stabilization, focus and colour locked, exposure every 10 s, 24 fps at most."
    }
  }

  func picture(stabilizes: Bool) -> CameraPicture {
    switch self {
    case .bestPicture: CameraPicture(stabilization: stabilizes, focus: .auto, exposure: .auto, whiteBalance: .auto)
    case .balanced: CameraPicture(stabilization: false, focus: .auto, exposure: .slow, whiteBalance: .slow)
    case .lowPower: CameraPicture(stabilization: false, focus: .locked, exposure: .slow, whiteBalance: .locked)
    }
  }

  /// Sets the camera's picture (and, for Low Power, its frame rate) to this profile
  func apply(to setup: inout CameraSetup, stabilizes: Bool) {
    setup.picture = picture(stabilizes: stabilizes)
    if self == .lowPower { setup.video.fps = min(setup.video.fps, 24) }
  }

  func matches(_ setup: CameraSetup) -> Bool {
    let picture = setup.picture
    switch self {
    case .bestPicture:
      return picture.focus == .auto && picture.exposure == .auto && picture.whiteBalance == .auto
    case .balanced, .lowPower:
      return picture == self.picture(stabilizes: false) && (self == .balanced || setup.video.fps <= 24)
    }
  }
}
#endif
