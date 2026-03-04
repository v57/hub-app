//
//  Foundation models.swift
//  Hub
//
//  Created by Linux on 08.10.25.
//

#if canImport(FoundationModels)
import SwiftUI
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
struct ChatView: View {
  @State var session = LanguageModelSession()
  @State var messages: [Message] = []
  @State var text: String = ""
  var body: some View {
    List(messages) { message in
      Text(message.text).contentTransition(.numericText())
    }.overlay {
      ZStack {
        if messages.isEmpty && text.isEmpty {
          Placeholder(image: "apple.intelligence", title: "Chat", description: "by Apple Intelligence") {
            Label("Use in your Hub", systemImage: "circle.hexagonpath.fill")
              .foregroundStyle(.red.gradient, .primary)
            Label("No internet needed", systemImage: "lock.badge.checkmark")
              .foregroundStyle(.green, .primary)
            Label("No chat history", systemImage: "lock.badge.checkmark")
              .foregroundStyle(.green, .primary)
            Label("Not smart, but fine", systemImage: "brain")
          }
        }
      }.animation(.smooth, value: messages.isEmpty && text.isEmpty)
    }.safeAreaInset(edge: .bottom) {
      HStack {
        #if os(visionOS)
        TextField("Type your message...", text: $text)
          .padding(.horizontal).padding(.vertical, 6)
        #else
        TextField("Type your message...", text: $text)
          .padding(.horizontal).padding(.vertical, 6)
          .textFieldStyle(.plain)
          .glassEffect(.regular, in: .capsule)
        #endif
        Button("Send") {
          Task { try await send(text: text) }
        }.disabled(session.isResponding || text.isEmpty).glassProminentButton()
      }.padding()
    }
  }
  @Observable
  class Message: Identifiable {
    var text: AttributedString
    init(text: String) {
      self.text = text.markdown
    }
  }
  func send(text: String) async throws {
    self.text = ""
    messages.append(Message(text: text))
    Task {
      let message = Message(text: "responding...")
      messages.append(message)
      do {
        for try await response in session.streamResponse(to: text) {
          withAnimation {
            message.text = response.content.markdown
          }
        }
      } catch {
        message.text = error.localizedDescription.markdown
      }
    }
  }
}
extension String {
  var markdown: AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly, failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: self, options: options)) ?? AttributedString(self)
  }
}

@available(macOS 26.0, iOS 26.0, *)
#Preview {
  ChatView().test()
}

#endif
