//
//  VideoCompressor.swift
//  Hub
//
//  Created by Linux on 19.07.25.
//

import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import VideoToolbox

public actor VideoEncoder {
  public enum Error: Swift.Error {
    case noVideo, writingError, unsupportedAudioChannelLayout(tag: AudioChannelLayoutTag), invalidVideoSettings(reason: String)
  }
  
  // Compression Encode Parameters
  public struct EncoderSettings: Sendable {
    public static func h264(bitrate: Int = 1_000_000, size: CGSize? = nil, maxKeyframeInterval: Int = 10, frameReordering: Bool = true, profile: H264.ProfileLevel = .highAuto, entropy: H264.Entropy = .cabac) -> Self {
      let settings = VideoCompressorSettings()
        .codec(.h264)
        .compression(bitrate: Float(bitrate), frameReordering: frameReordering, profile: profile, entropy: entropy)
        .keyframeInterval(maxKeyframeInterval)
      var config = EncoderSettings(settings: settings, fileType: .mp4, size: size)
      config.bitrate = Float(bitrate)
      return config
    }
    public static func hevc(quality: Float, size: CGSize?, frameReordering: Bool = false, hdr: Bool = true, profile: Hevc.ProfileLevel = .main) -> Self {
      var settings = VideoCompressorSettings()
        .codec(.hevc)
        .compression(quality: quality, frameReordering: frameReordering, profile: profile)
      if !hdr {
        settings = settings.color(.hd).wideColor(false)
      }
      var config = EncoderSettings(settings: settings, fileType: .mov, size: size)
      config.quality = quality
      return config
    }
    
    public static func other(codec: AVVideoCodecType, quality: Float, size: CGSize?, frameReordering: Bool = true, profile: Hevc.ProfileLevel = .main) -> Self {
      let settings = VideoCompressorSettings()
        .codec(codec)
        .compression(quality: quality, frameReordering: frameReordering, profile: profile)
      var config = EncoderSettings(settings: settings, fileType: .mov, size: size)
      config.quality = quality
      return config
    }
    
    public var settings: VideoCompressorSettings
    public var fileType: AVFileType
    public var size: CGSize?
    var bitrate: Float?
    var quality: Float?
    init(settings: VideoCompressorSettings, fileType: AVFileType, size: CGSize?) {
      self.settings = settings
      self.fileType = fileType
      self.size = size
    }
  }
  public init() { }
  
  struct VideoTrack {
    let track: AVAssetTrack
    let settings: [String: Any]
    let transform: CGAffineTransform
  }
  
  struct AudioTrack {
    let track: AVAssetTrack
    let dataRate: Float
    let sampleRate: Double
    let channels: Int
    let channelLayout: Data?
    var readerSettings: [String: Any] {
      var settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: max(channels, 1),
      ]
      if let channelLayout {
        settings[AVChannelLayoutKey] = channelLayout
      }
      return settings
    }
    func writerSettings() throws -> [String: Any] {
      let channelCount = max(channels, 1)
      let minimumBitrate = Float(max(channels, 1) * 64_000)
      var settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVEncoderBitRateKey: max(dataRate, minimumBitrate),
        AVNumberOfChannelsKey: channelCount,
      ]
      settings[AVChannelLayoutKey] = try resolvedChannelLayout()
      return settings
    }
    
    private func resolvedChannelLayout() throws -> Data {
      let channelCount = max(channels, 1)
      if let layout = channelLayout,
         let parsedLayout = layout.audioChannelLayout(),
         parsedLayout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
        return layout
      }
      if let layout = channelLayout,
         let parsedLayout = layout.audioChannelLayout(),
         isSupported(aacChannelLayout: parsedLayout, sampleRate: sampleRate, channels: channelCount) {
        return layout
      }
      if let fallback = availableFallbackChannelLayout(sampleRate: sampleRate, channels: channelCount) {
        return fallback
      }
      for tag in [kAudioChannelLayoutTag_Mono, kAudioChannelLayoutTag_Stereo] {
        var fallbackLayout = AudioChannelLayout()
        memset(&fallbackLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        fallbackLayout.mChannelLayoutTag = tag
        if isSupported(aacChannelLayout: fallbackLayout, sampleRate: sampleRate, channels: channelCount) {
          return Data(bytes: &fallbackLayout, count: MemoryLayout<AudioChannelLayout>.size)
        }
      }
      throw Error.unsupportedAudioChannelLayout(tag: 0)
    }
    
    private func availableFallbackChannelLayout(sampleRate: Double, channels: Int) -> Data? {
      for tag in supportedAACChannelLayoutTags(sampleRate: sampleRate, channels: channels) where tag != 0 {
        var candidate = AudioChannelLayout()
        memset(&candidate, 0, MemoryLayout<AudioChannelLayout>.size)
        candidate.mChannelLayoutTag = tag
        if isSupported(aacChannelLayout: candidate, sampleRate: sampleRate, channels: channels) {
          return Data(bytes: &candidate, count: MemoryLayout<AudioChannelLayout>.size)
        }
      }
      return nil
    }
    
    private func supportedAACChannelLayoutTags(sampleRate: Double, channels: Int) -> [AudioChannelLayoutTag] {
      var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatMPEG4AAC,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: 1024,
        mBytesPerFrame: 0,
        mChannelsPerFrame: UInt32(max(channels, 1)),
        mBitsPerChannel: 0,
        mReserved: 0
      )
      var propertySize: UInt32 = 0
      var status = AudioFormatGetPropertyInfo(
        kAudioFormatProperty_AvailableEncodeChannelLayoutTags,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &asbd,
        &propertySize
      )
      guard status == noErr, propertySize > 0 else { return [] }
      let count = Int(propertySize / UInt32(MemoryLayout<AudioChannelLayoutTag>.size))
      guard count > 0 else { return [] }
      var availableTags = Array(repeating: AudioChannelLayoutTag(), count: count)
      status = AudioFormatGetProperty(
        kAudioFormatProperty_AvailableEncodeChannelLayoutTags,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &asbd,
        &propertySize,
        &availableTags
      )
      guard status == noErr else { return [] }
      return availableTags
    }
    
    private func isSupported(aacChannelLayout: AudioChannelLayout, sampleRate: Double, channels: Int) -> Bool {
      var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatMPEG4AAC,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: 1024,
        mBytesPerFrame: 0,
        mChannelsPerFrame: UInt32(max(channels, 1)),
        mBitsPerChannel: 0,
        mReserved: 0
      )
      var propertySize: UInt32 = 0
      var status = AudioFormatGetPropertyInfo(
        kAudioFormatProperty_AvailableEncodeChannelLayoutTags,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &asbd,
        &propertySize
      )
      guard status == noErr, propertySize > 0 else { return false }
      let count = Int(propertySize / UInt32(MemoryLayout<AudioChannelLayoutTag>.size))
      guard count > 0 else { return false }
      var availableTags = Array(repeating: AudioChannelLayoutTag(), count: count)
      status = AudioFormatGetProperty(
        kAudioFormatProperty_AvailableEncodeChannelLayoutTags,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &asbd,
        &propertySize,
        &availableTags
      )
      guard status == noErr else { return false }
      return availableTags.contains(aacChannelLayout.mChannelLayoutTag)
    }
  }
  
  private struct ProcessPipeline: @unchecked Sendable {
    let input: AVAssetWriterInput
    let output: AVAssetReaderTrackOutput
    let progress: CompressionProgress?
  }
  
  
  public func encode(from asset: AVAsset, to: URL, settings: EncoderSettings, progress: @escaping @Sendable @MainActor (CMTime, CMTime) -> Void) async throws {
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    guard !videoTracks.isEmpty else { throw Error.noVideo }
    var videos: [VideoTrack] = []
    videos.reserveCapacity(videoTracks.count)
    for track in videoTracks {
      let (videoSize, transform) = try await track.load(.naturalSize, .preferredTransform)
      let targetSize = mapSize(settings.size, size: videoSize)
      let videoSettings = settings.settings.width(targetSize.width).height(targetSize.height).settings
      videos.append(VideoTrack(track: track, settings: videoSettings, transform: transform))
    }
    
    let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
    var audios: [AudioTrack] = []
    audios.reserveCapacity(sourceAudioTracks.count)
    for track in sourceAudioTracks {
      let dataRate = try await track.load(.estimatedDataRate)
      let formatDescriptions = try await track.load(.formatDescriptions)
      var sampleRate = 44_100.0
      var channels = 2
      var channelLayout: Data?
      if let formatDescription = formatDescriptions.first {
        if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
          sampleRate = streamDescription.pointee.mSampleRate
          channels = Int(streamDescription.pointee.mChannelsPerFrame)
        }
        var layoutSize = 0
        if
          let layout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &layoutSize),
          layoutSize > 0
        {
          channelLayout = Data(bytes: layout, count: layoutSize)
        }
      }
      audios.append(
        AudioTrack(
          track: track,
          dataRate: dataRate,
          sampleRate: sampleRate,
          channels: channels,
          channelLayout: channelLayout
        )
      )
    }
    
    let duration: CMTime = try await asset.load(.duration)
    let progressTracker = CompressionProgress(duration: duration, callback: progress)
    
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(url: to, fileType: settings.fileType)
    
    var pipelines: [ProcessPipeline] = []
    pipelines.reserveCapacity(videos.count + audios.count)
    var hasProgressPipeline = false
    for video in videos {
      let videoOutput = AVAssetReaderTrackOutput(
        track: video.track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      )
      guard reader.canAdd(videoOutput) else { throw Error.writingError }
      reader.add(videoOutput)
      videoOutput.alwaysCopiesSampleData = false
      let outputSettings = validatedVideoSettings(video.settings, writer: writer)
      let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
      guard writer.canAdd(videoInput) else {
        throw Error.invalidVideoSettings(reason: "The provided video settings are not supported by AVAssetWriter.")
      }
      videoInput.transform = video.transform
      guard writer.canAdd(videoInput) else { throw Error.writingError }
      writer.add(videoInput)
      
      let pipelineProgress: CompressionProgress?
      if hasProgressPipeline {
        pipelineProgress = nil
      } else {
        pipelineProgress = progressTracker
        hasProgressPipeline = true
      }
      pipelines.append(ProcessPipeline(input: videoInput, output: videoOutput, progress: pipelineProgress))
    }
    
    for audio in audios {
      let audioOutput = AVAssetReaderTrackOutput(track: audio.track, outputSettings: audio.readerSettings)
      guard reader.canAdd(audioOutput) else { throw Error.writingError }
      reader.add(audioOutput)
      let audioWriterSettings = try audio.writerSettings()
      let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioWriterSettings)
      guard writer.canAdd(audioInput) else { throw Error.writingError }
      writer.add(audioInput)
      
      pipelines.append(ProcessPipeline(input: audioInput, output: audioOutput, progress: nil))
    }
    
    guard reader.startReading() else {
      throw reader.error ?? Error.writingError
    }
    guard writer.startWriting() else {
      throw writer.error ?? Error.writingError
    }
    writer.startSession(atSourceTime: CMTime.zero)
    
    await withTaskGroup(of: Void.self) { group in
      for pipeline in pipelines {
        group.addTask { [self] in
          await self.process(input: pipeline.input, output: pipeline.output, progress: pipeline.progress)
        }
      }
      await group.waitForAll()
    }
    switch writer.status {
    case .writing, .completed:
      await withCheckedContinuation { continuation in
        writer.finishWriting {
          continuation.resume()
        }
      }
    default:
      throw writer.error ?? Error.writingError
    }
  }
  
  
  private func process(input: AVAssetWriterInput?, output: AVAssetReaderOutput?, progress: CompressionProgress?) async {
    guard let i = input, let o = output else { return }
    nonisolated(unsafe) let input = i
    nonisolated(unsafe) let output = o
    await withCheckedContinuation { continuation in
      let queue = DispatchQueue(label: "Video encoder")
      input.requestMediaDataWhenReady(on: queue) {
        while input.isReadyForMoreMediaData {
          if let buffer = output.copyNextSampleBuffer() {
            if let progress {
              let time = CMSampleBufferGetPresentationTimeStamp(buffer)
              Task { @MainActor in
                progress.send(progress: time)
              }
            }
            input.append(buffer)
          } else {
            input.markAsFinished()
            continuation.resume()
            return
          }
        }
      }
    }
  }
  func mapSize(_ target: CGSize?, size: CGSize) -> CGSize {
    guard let target else { return size }
    if target.width == -1 && target.height == -1 {
      return size
    } else if target.width != -1 && target.height != -1 {
      return target
    } else if target.width == -1 {
      let width = target.height * size.width / size.height
      return CGSize(width: width.rounded(.down), height: target.height)
    } else {
      let height = target.width * size.height / size.width
      return CGSize(width: target.width, height: height.rounded(.down))
    }
  }
  
  private func validatedVideoSettings(_ settings: [String: Any], writer: AVAssetWriter) -> [String: Any] {
    if writer.canApply(outputSettings: settings, forMediaType: .video) {
      return settings
    }
    var fallbackSettings = settings
    fallbackSettings.removeValue(forKey: AVVideoAllowWideColorKey)
    fallbackSettings.removeValue(forKey: AVVideoColorPropertiesKey)
    if writer.canApply(outputSettings: fallbackSettings, forMediaType: .video) {
      return fallbackSettings
    }
    return settings
  }
}

private extension Data {
  func audioChannelLayout() -> AudioChannelLayout? {
    guard count >= MemoryLayout<AudioChannelLayout>.size else { return nil }
    return withUnsafeBytes { bytes in
      bytes
        .bindMemory(to: AudioChannelLayout.self)
        .baseAddress?
        .pointee
    }
  }
}

private struct CompressionProgress: Sendable {
  var duration: CMTime
  let callback: @Sendable @MainActor (CMTime, CMTime) -> ()
  @MainActor
  func send(progress: CMTime) {
    callback(duration, progress)
  }
}

public struct VideoCompressorSettings: @unchecked Sendable {
  public var settings: [String: Any] = [:]
  public init(settings: [String : Any] = [:]) {
    self.settings = settings
  }
}
public extension VideoCompressorSettings {
  func codec(_ value: AVVideoCodecType) -> Self {
    set(AVVideoCodecKey, value)
  }
  func scaling(_ value: ScalingMode) -> Self {
    set(AVVideoScalingModeKey, value.rawValue)
  }
  func width(_ value: Double) -> Self {
    set(AVVideoWidthKey, value.rounded(.down))
  }
  func height(_ value: Double) -> Self {
    set(AVVideoHeightKey, value.rounded(.down))
  }
  func wideColor(_ value: Bool = true) -> Self {
    set(AVVideoAllowWideColorKey, value)
  }
  func pixelAspectRatio(horizontal: Double = 1, vertical: Double = 1) -> Self {
    set(AVVideoPixelAspectRatioKey, [
      AVVideoPixelAspectRatioHorizontalSpacingKey: horizontal,
      AVVideoPixelAspectRatioVerticalSpacingKey: vertical
    ])
  }
  func cleanAperture(frame: CGRect) -> Self {
    set(AVVideoCleanApertureKey, [
      AVVideoCleanApertureWidthKey: frame.width,
      AVVideoCleanApertureHeightKey: frame.height,
      AVVideoCleanApertureHorizontalOffsetKey: frame.minX,
      AVVideoCleanApertureVerticalOffsetKey: frame.minY,
    ])
  }
  func color(_ value: Color) -> Self {
    set(AVVideoColorPropertiesKey, value.rawValue)
  }
  func allowFrameReordering(_ value: Bool) -> Self {
    set(AVVideoAllowFrameReorderingKey, value)
  }
  func compression(bitrate: Float, frameReordering: Bool, profile: H264.ProfileLevel = .highAuto, entropy: H264.Entropy = .cabac) -> Self {
    compression {
      $0[AVVideoAverageBitRateKey] = bitrate
      $0[AVVideoAllowFrameReorderingKey] = frameReordering
      $0[AVVideoProfileLevelKey] = profile.rawValue
      $0[AVVideoH264EntropyModeKey] = entropy.rawValue
    }
  }
  func compression(quality: Float, frameReordering: Bool, profile: Hevc.ProfileLevel = .main) -> Self {
    compression {
      $0[AVVideoQualityKey] = quality
      $0[AVVideoAllowFrameReorderingKey] = frameReordering
      $0[AVVideoProfileLevelKey] = profile.rawValue
    }
  }
  func keyframeInterval(_ value: Int) -> Self {
    compression { $0[AVVideoMaxKeyFrameIntervalKey] = value }
  }
  func expectedFramerate(_ value: Float) -> Self {
    compression { $0[AVVideoExpectedSourceFrameRateKey] = value }
  }
  func nonDroppableFramerate(_ value: Float) -> Self {
    compression { $0[AVVideoAverageNonDroppableFrameRateKey] = value }
  }
  private func compression(_ edit: (inout [String: Any]) -> ()) -> Self {
    var settings = settings
    var compression: [String: Any] = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
    edit(&compression)
    settings[AVVideoCompressionPropertiesKey] = compression
    return VideoCompressorSettings(settings: settings)
  }
  
  private func set(_ key: String, _ value: Any) -> Self {
    var compressor = self
    compressor.settings[key] = value
    return compressor
  }
  enum ScalingMode {
    case fit, resize, aspectFit, aspectFill
    var rawValue: String {
      switch self {
      case .fit: return AVVideoScalingModeFit
      case .resize: return AVVideoScalingModeResize
      case .aspectFit: return AVVideoScalingModeResizeAspect
      case .aspectFill: return AVVideoScalingModeResizeAspectFill
      }
    }
  }
  enum Color {
    case hd, sd, wideGamut, wideGamut10Bit
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
    case hdrLinear
    var rawValue: [String: String] {
      switch self {
      case .hd:
        return [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
      case .sd:
        return [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
        ]
      case .wideGamut:
        return [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
      case .wideGamut10Bit:
        return [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
      case .hdrLinear:
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
          return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
          ]
        } else {
          return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
          ]
        }
      }
    }
  }
}

public enum Hevc {
  public enum ProfileLevel {
    case main, main10, main42210
    var rawValue: String {
      switch self {
      case .main: return kVTProfileLevel_HEVC_Main_AutoLevel as String
      case .main10: return kVTProfileLevel_HEVC_Main10_AutoLevel as String
      case .main42210: if #available(iOS 15.4, macOS 12.3, tvOS 15.4, *) {
        return kVTProfileLevel_HEVC_Main42210_AutoLevel as String
      } else {
        return kVTProfileLevel_HEVC_Main10_AutoLevel as String
      }
      }
    }
  }
}

public enum H264 {
  public enum ProfileLevel {
    case baseline30, baseline31, baseline41, baselineAuto
    case main30, main31, main32, main41, mainAuto
    case high40, high41, highAuto
    
    var rawValue: String {
      switch self {
      case .baseline30: return AVVideoProfileLevelH264Baseline30
      case .baseline31: return AVVideoProfileLevelH264Baseline31
      case .baseline41: return AVVideoProfileLevelH264Baseline41
      case .baselineAuto: return AVVideoProfileLevelH264BaselineAutoLevel
      case .main30: return AVVideoProfileLevelH264Main30
      case .main31: return AVVideoProfileLevelH264Main31
      case .main32: return AVVideoProfileLevelH264Main32
      case .main41: return AVVideoProfileLevelH264Main41
      case .mainAuto: return AVVideoProfileLevelH264MainAutoLevel
      case .high40: return AVVideoProfileLevelH264High40
      case .high41: return AVVideoProfileLevelH264High41
      case .highAuto: return AVVideoProfileLevelH264HighAutoLevel
      }
    }
  }
  public enum Entropy {
    case cavlc, cabac
    var rawValue: String {
      switch self {
      case .cavlc: return AVVideoH264EntropyModeCAVLC
      case .cabac: return AVVideoH264EntropyModeCABAC
      }
    }
  }
}
