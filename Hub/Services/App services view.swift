//
//  App services view.swift
//  Hub
//
//  Created by Linux on 17.10.25.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

extension AppServices {
  struct Page: View {
    let service: Service
    var body: some View {
      switch service {
      case .chat:
#if !canImport(SwiftCrossUI) && os(macOS) || os(iOS)
        if #available(macOS 26.0, iOS 26.0, *) {
          ChatView()
        } else {
          ContentUnavailableView("Service not available", systemImage: "translate", description: Text("Translation feature was introduced in \(Text("iOS 26").bold()) and \(Text("macOS 26").bold()) for devices with \(Text("Apple Intelligence").bold()) so it's not possible to run it on other devices or lower versions"))
        }
#else
        ContentUnavailableView("Service not available", systemImage: "translate", description: Text("Translation feature was introduced in \(Text("iOS 26").bold()) and \(Text("macOS 26").bold()) for devices with \(Text("Apple Intelligence").bold()) so it's not possible to run it on other devices or lower versions"))
#endif
      case .imageEncoder:
#if os(macOS) || os(iOS) || os(visionOS)
        ImageEncoderView()
#else
        ContentUnavailableView("Service not available", systemImage: "photo.fill", description: Text("Image encoder interface is not available on Apple Watch and Apple TV but you can still use it as a service"))
#endif
      case .videoEncoder:
#if os(macOS) || os(iOS) || os(visionOS)
        VideoEncoderView()
#else
        ContentUnavailableView("Service not available", systemImage: "photo.fill", description: Text("Video encoder interface is not available yet but you can still use it as a service"))
#endif
      case .translate:
#if !canImport(SwiftCrossUI) && os(macOS) || os(iOS)
        if #available(macOS 15.0, iOS 18.0, *) {
          TranslateView()
        } else {
          ContentUnavailableView("Service not available", systemImage: "translate", description: Text("Translation feature was introduced in \(Text("iOS 18").bold()) and \(Text("macOS 15").bold()) so it's not possible to run it on other devices or lower versions"))
        }
#else
        ContentUnavailableView("Service not available", systemImage: "translate", description: Text("Translation feature was introduced in \(Text("iOS 18").bold()) and \(Text("macOS 15").bold()) so it's not possible to run it on other devices or lower versions"))
#endif
      case .sensitiveContent:
#if os(macOS) || os(iOS) || os(visionOS)
        SensitiveContentView()
#endif
      }
    }
  }
  struct HubButton: View {
    let hub: Hub
    let service: Service
    @State var isEnabled: Bool = false
    var body: some View {
      Button {
        withAnimation {
          isEnabled.toggle()
        }
        service.set(enabled: isEnabled, hub: hub)
      } label: {
        ServiceContent(item: service, isSharing: isEnabled)
      }.buttonStyle(.plain)
    }
  }
  struct ServiceContent: View {
    let item: Service
    let isSharing: Bool?
    var body: some View {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.gray.opacity(0.2))
        .overlay {
          Image(systemName: item.image)
            .font(.system(size: 17.6)).fontWeight(.medium)
        }.frame(width: 44, height: 44).overlay(alignment: .topTrailing) {
          if let isSharing {
            Image(systemName: "square.and.arrow.up.circle.fill")
              .foregroundStyle(isSharing ? .white : .primary, isSharing ? .blue : .tertiaryBackground)
              .font(.title).labelStyle(.iconOnly)
              .offset(x: 6, y: -4)
          }
        }
      VStack(alignment: .leading) {
        HStack {
          Text(item.title).lineLimit(2)
        }
        Text(item.description).secondary().lineLimit(3)
      }
    }
  }
  enum Service: Int, CaseIterable {
    case imageEncoder, videoEncoder, translate, chat, sensitiveContent
    var id: String {
      switch self {
      case .imageEncoder: return "image/encode"
      case .videoEncoder: return "video/encode"
      case .translate: return "text/translate"
      case .chat: return "text/llm"
      case .sensitiveContent: return "image/sensitive"
      }
    }
    init?(id: String) {
      switch id {
      case "image/encode": self = .imageEncoder
      case "video/encode": self = .videoEncoder
      case "text/translate": self = .translate
      case "text/llm": self = .chat
      case "image/sensitive": self = .sensitiveContent
      default: return nil
      }
    }
    var title: LocalizedStringKey {
      switch self {
      case .imageEncoder: return "Image encoder"
      case .videoEncoder: return "Video encoder"
      case .sensitiveContent: return "Detect sensitive content"
      case .translate: return "Apple Intelligence Translate"
      case .chat: return "Apple Intelligence Chat"
      }
    }
    var image: String {
      switch self {
      case .imageEncoder: return "photo"
      case .videoEncoder: return "video"
      case .sensitiveContent: return "photo.badge.magnifyingglass"
      case .translate: return "translate"
      case .chat: return "apple.intelligence"
      }
    }
    var description: String {
      switch self {
      case .imageEncoder: return "Compress images by converting them to .heic format"
      case .videoEncoder: return "Compress images by converting them to .hevc format"
      case .sensitiveContent: return "Detect if image or video contains sensitive content"
      case .translate: return "Translate text using on device translation"
      case .chat: return "Chat with apple intelligence on device model"
      }
    }
    @MainActor
    func isEnabled(hub: Hub) -> Bool? {
      switch self {
      case .imageEncoder: hub.appServices.image?.isEnabled
      case .videoEncoder: hub.appServices.video?.isEnabled
      case .translate: hub.appServices.translation?.isEnabled
      case .chat: hub.appServices.chat?.isEnabled
      case .sensitiveContent: hub.appServices.sensitiveContent?.isEnabled
      }
    }
    @MainActor
    func set(enabled: Bool, hub: Hub) {
      switch self {
      case .imageEncoder: hub.appServices.image?.isEnabled = enabled
      case .videoEncoder: hub.appServices.video?.isEnabled = enabled
      case .translate: hub.appServices.translation?.isEnabled = enabled
      case .chat: hub.appServices.chat?.isEnabled = enabled
      case .sensitiveContent: hub.appServices.sensitiveContent?.isEnabled = enabled
      }
    }
    @MainActor
    func toggle(hub: Hub) {
      switch self {
      case .imageEncoder: hub.appServices.image?.isEnabled.toggle()
      case .videoEncoder: hub.appServices.video?.isEnabled.toggle()
      case .translate: hub.appServices.translation?.isEnabled.toggle()
      case .chat: hub.appServices.chat?.isEnabled.toggle()
      case .sensitiveContent: hub.appServices.sensitiveContent?.isEnabled.toggle()
      }
    }
  }
  enum Availability {
    case available, iOS(Int), macOS(Int), unsupportedDevice
  }
}
