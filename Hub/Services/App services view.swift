//
//  App services view.swift
//  Hub
//
//  Created by Linux on 17.10.25.
//

import SwiftUI

extension AppServices {
  struct Page: View {
    let service: Service
    var body: some View {
      switch service {
      case .chat:
#if os(macOS) || os(iOS)
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
#if os(macOS) || os(iOS)
        VideoEncoderView()
#else
        ContentUnavailableView("Service not available", systemImage: "photo.fill", description: Text("Video encoder interface is not available yet but you can still use it as a service"))
#endif
      case .translate:
#if os(macOS) || os(iOS)
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
    let publisher: Published<Bool>.Publisher
    let service: Service
    @State var isEnabled: Bool = false
    var body: some View {
      Button {
        withAnimation {
          isEnabled.toggle()
        }
        service.setService(enabled: isEnabled, hub: hub)
      } label: {
        ServiceContent(item: service, isSharing: isEnabled)
      }.onReceive(publisher) { isEnabled = $0 }
        .buttonStyle(.plain)
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
  enum Service: CaseIterable {
    case imageEncoder, videoEncoder, translate, chat, sensitiveContent
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
    func servicePublisher(hub: Hub) -> Published<Bool>.Publisher? {
      switch self {
      case .imageEncoder: hub.appServices.image.$isEnabled
      case .videoEncoder: hub.appServices.video.$isEnabled
      case .translate:
#if os(macOS) || os(iOS)
        hub.appServices.$translationEnabled
#else
        nil
#endif
      case .chat: hub.appServices.chat?.$isEnabled
      case .sensitiveContent:
#if os(macOS) || os(iOS)
        hub.appServices.sensitiveContent.$isEnabled
#else
        nil
#endif
      }
    }
    @MainActor
    func setService(enabled: Bool, hub: Hub) {
      switch self {
      case .imageEncoder: hub.appServices.image.isEnabled = enabled
      case .videoEncoder: hub.appServices.video.isEnabled = enabled
      case .translate:
#if os(macOS) || os(iOS)
        hub.appServices.translationEnabled = enabled
#else
        break
#endif
      case .chat: hub.appServices.chat?.isEnabled = enabled
      case .sensitiveContent:
#if os(macOS) || os(iOS)
        hub.appServices.sensitiveContent.isEnabled = enabled
#else
        break
#endif
      }
    }
  }
  enum Availability {
    case available, iOS(Int), macOS(Int), unsupportedDevice
  }
}

extension Color {
  static var tertiaryBackground: Color {
#if os(macOS) || os(iOS)
    Color(.tertiarySystemFill)
#else
    Color.gray.opacity(0.4)
#endif
  }
}
