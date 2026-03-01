//
//  Image encoder.swift
//  Hub
//
//  Created by Linux on 27.09.25.
//

import Foundation
import ImageIO
import CoreGraphics
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

extension Data {
  enum ImageError: Error {
    case cannotCreateImageSource
    case cannotCreateCGImage
    case cannotCreateDestination
    case finalizeFailed
  }
  func image(format: String, quality: CGFloat, metadata: Bool) throws -> Data {
    guard let source = CGImageSourceCreateWithData(self as CFData, nil), CGImageSourceGetCount(source) > 0 else {
      throw ImageError.cannotCreateImageSource
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
      kCGImageSourceShouldCache: true as CFBoolean
    ] as CFDictionary) else { throw ImageError.cannotCreateCGImage }
    let result = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(result, "public.\(format)" as CFString, 1, nil) else {
      throw ImageError.cannotCreateDestination
    }
    var imageProperties: [CFString: Any] = [:]
    if metadata, let allProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
      imageProperties = allProps
      imageProperties.removeValue(forKey: kCGImagePropertyTIFFDictionary)
    }
    imageProperties.removeValue(forKey: kCGImagePropertyOrientation)
    imageProperties[kCGImageDestinationLossyCompressionQuality] = quality
    CGImageDestinationAddImage(destination, cgImage, imageProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImageError.finalizeFailed }
    return result as Data
  }
}
