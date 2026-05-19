//
//  Chat service.swift
//  Hub
//
//  Created by Linux on 30.10.25.
//

#if canImport(FoundationModels)
import Foundation
import FoundationModels
import HubService

extension HubService.Group {
  @available(macOS 26.0, iOS 26.0, *)
  func chat() -> Self {
    post("text/llm/apple", options: .init(limit: 2)) { (request: ChatRequest) in
      try await Statistics.updating(.chat) {
        try await request.response()
      }
    }.stream("text/llm/apple", options: .init(limit: 2)) { (request: ChatRequest, continuation) in
      try await Statistics.updating(.chat) {
        try await request.stream(continuation: continuation)
      }
    }
  }
}

@available(macOS 26.0, iOS 26.0, *)
struct ChatRequest: Decodable {
  let messages: [Message]
  enum Role: String, Decodable {
    case user, assistant, instruction
  }
  struct Message: Decodable {
    let role: String
    let content: String
    var transcriptEntry: Transcript.Entry {
      let segments = [Transcript.Segment.text(Transcript.TextSegment(content: content))]
      switch role {
      case "assistant":
        return .response(.init(assetIDs: [], segments: segments))
      case "instruction":
        return .instructions(.init(segments: segments, toolDefinitions: []))
      default:
        return .prompt(.init(segments: segments))
      }
    }
  }
  var session: LanguageModelSession {
    LanguageModelSession(transcript: .init(entries: messages.map(\.transcriptEntry).dropLast()))
  }
  func response() async throws -> String {
    guard let last = messages.last else { return "" }
    return try await session.respond(to: last.content).content
  }
  func stream(continuation: AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws {
    guard let last = messages.last else {
      continuation.yield("")
      return }
    for try await text in session.streamResponse(to: last.content) {
      continuation.yield(text.content)
    }
  }
}
#endif
