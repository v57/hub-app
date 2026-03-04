//
//  File.swift
//  Hub
//
//  Created by Linux on 05.10.25.
//

#if canImport(SensitiveContentAnalysis)
import SwiftUI
import SensitiveContentAnalysis
import AVKit

extension SCSensitivityAnalyzer {
  static let shared = SCSensitivityAnalyzer()
  static var isAvailable: Bool {
    shared.analysisPolicy != .disabled
  }
}
extension URL {
  func isSensitive() async -> Bool {
    do {
      switch lastPathComponent.fileType {
      case .image:
        return try await SCSensitivityAnalyzer.shared.analyzeImage(at: self).isSensitive
      case .video:
        return try await SCSensitivityAnalyzer.shared.videoAnalysis(forFileAt: self).hasSensitiveContent().isSensitive
      case .audio, .document:
        return false
      }
    } catch {
      return false
    }
  }
}

struct SensitiveContentView: View {
  @State var items = [Item]()
  var body: some View {
    ScrollView {
      LazyVGrid(columns: [.init(.adaptive(minimum: 64))]) {
        ForEach(items) { item in
          Preview(item: item)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .safeAreaPadding()
    }.overlay {
      VStack {
        if items.isEmpty {
          Placeholder(image: "photo.badge.magnifyingglass", title: "Detect Sensitive Content", description: "Helps with moderation on your server") {
            Label("Use in your Hub", systemImage: "circle.hexagonpath.fill")
              .foregroundStyle(.red.gradient, .primary)
            Label("No internet needed", systemImage: "lock.badge.checkmark")
              .foregroundStyle(.green, .primary)
            Label("Drop files here to check them", systemImage: "arrow.down.app")
          }
        }
      }.animation(.smooth, value: items.isEmpty).allowsHitTesting(false)
    }.dropFiles { (urls: [URL], point: CGPoint) -> Bool in
      withAnimation {
        items.append(contentsOf: urls.map { Item(url: $0) })
      }
      return true
    }
  }
  @Observable class Item: Identifiable {
    let id = UUID()
    let url: URL
    var isSensitive: Bool?
    init(url: URL) {
      self.url = url
    }
    func check() async {
      guard isSensitive == nil else { return }
      isSensitive = await url.isSensitive()
    }
  }
  struct Preview: View {
    let item: Item
    @State var image: Image?
    @Environment(\.displayScale) var imageScale
    var body: some View {
      Color(.secondarySystemFill).overlay {
        image?.resizable().scaledToFill()
          .transition(.scale)
      }.overlay {
        if let isSensitive = item.isSensitive {
          Image(systemName: isSensitive ? "xmark.seal.fill" : "checkmark.seal.fill")
            .foregroundStyle(.white, isSensitive ? .red : .green)
            .font(.title)
            .shadow(radius: 1, y: 1)
            .transition(.scale)
        }
      }.animation(.smooth, value: item.isSensitive).task(id: item.id) {
        await item.check()
      }.clipShape(RoundedRectangle(cornerRadius: 16))
        .aspectRatio(1, contentMode: .fill)
        .task(id: item.id) {
          guard image == nil else { return }
          switch item.url.lastPathComponent.fileType {
          case .image:
            #if os(macOS)
            if let image = NSImage(contentsOf: item.url) {
              self.image = Image(nsImage: image)
            }
            #else
            if let image = UIImage(contentsOfFile: item.url.absoluteString)?.cgImage?.resize(to: CGSize(width: 64 * imageScale, height: 64 * imageScale)) {
              self.image = Image(image, scale: 1, label: Text(""))
            }
            #endif
          case .video:
            AVAssetImageGenerator(asset: AVURLAsset(url: item.url)).generateCGImageAsynchronously(for: .zero) { image, _, _ in
              guard let image = image?.resize(to: CGSize(width: 64 * imageScale, height: 64 * imageScale)) else { return }
              withAnimation {
                self.image = Image(image, scale: 1, label: Text(""))
              }
            }
          default: break
          }
        }.transition(.scale)
    }
  }
}

private extension CGImage {
  func resize(to size: CGSize) -> CGImage {
    let w = Int(size.width)
    let h = Int(size.height)
    guard let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
      return self
    }
    guard let context = CGContext(
      data: nil,
      width: w,
      height: h,
      bitsPerComponent: bitsPerComponent,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: bitmapInfo.rawValue
    ) else { return self }
    let source = CGFloat(width) / CGFloat(height)
    let target = size.width / size.height
    if source > target {
      let width = size.height * source
      context.draw(self, in: CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height))
    } else {
      let height = size.width / source
      context.draw(self, in: CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height))
    }
    return context.makeImage() ?? self
  }
}

#Preview {
  SensitiveContentView()
}
#endif
