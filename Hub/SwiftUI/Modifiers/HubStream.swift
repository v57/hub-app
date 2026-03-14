//
//  HubStream.swift
//  Hub
//
//  Created by Dmitry Kozlov on 21/6/25.
//

import SwiftUI

extension View {
  // MARK: Without body
  func hubStream<T: Decodable>(_ path: String, initial: T? = nil, delayed: Bool = true, action: @MainActor @escaping (T) -> Void) -> some View {
    modifier(HubStreamModifier(path: path, initial: initial, delayed: delayed, action: action))
  }
  func hubStream<T: Decodable>(_ path: String, initial: T? = nil, to: Binding<T>, delayed: Bool = true) -> some View {
    hubStream(path, initial: initial, delayed: delayed) { (value: T) in
      to.wrappedValue = value
    }
  }
  func hubStream<T: Decodable>(_ path: String, initial: T?, to: Binding<T?>, delayed: Bool = true) -> some View {
    hubStream(path, initial: initial, delayed: delayed) { (value: T) in
      to.wrappedValue = value
    }
  }
  // MARK: With body
  func hubStream<T: Decodable, Body>(_ path: String, _ body: Body, initial: T? = nil, delayed: Bool = true, action: @MainActor @escaping (T) -> Void) -> some View
  where Body: Encodable & Sendable & Hashable {
    modifier(HubStreamBodyModifier(path: path, body: body, initial: initial, delayed: delayed, action: action))
  }
  func hubStream<T: Decodable, Body>(_ path: String, _ body: Body, initial: T? = nil, to: Binding<T>, delayed: Bool = true) -> some View
  where Body: Encodable & Sendable & Hashable {
    hubStream(path, body, initial: initial, delayed: delayed) { (value: T) in
      to.wrappedValue = value
    }
  }
  func hubStream<T: Decodable, Body>(_ path: String, _ body: Body, initial: T?, to: Binding<T?>, delayed: Bool = true) -> some View
  where Body: Encodable & Sendable & Hashable {
    hubStream(path, body, initial: initial, delayed: delayed) { (value: T) in
      to.wrappedValue = value
    }
  }
}

private struct HubStreamModifier<T: Decodable>: ViewModifier {
  let path: String
  let initial: T?
  let delayed: Bool
  let action: @MainActor (T) -> Void
  @Environment(Hub.self) private var hub
  func body(content: Content) -> some View {
    content.task(id: hub.taskId(path: path)) {
      if let initial {
        action(initial)
      }
      guard hub.isConnected && hub.api.contains(path) else { return }
      do {
        for try await value: T in hub.client.values(path) {
          if delayed {
            EventDelayManager.main.execute {
              action(value)
            }
          } else {
            action(value)
          }
        }
      } catch is CancellationError {
        
      } catch {
        print("\(path):", error)
      }
    }
  }
}
private struct HubStreamBodyModifier<T: Decodable, Body: Encodable & Hashable & Sendable>: ViewModifier {
  let path: String
  let body: Body
  let initial: T?
  let delayed: Bool
  let action: @MainActor (T) -> Void
  @Environment(Hub.self) private var hub
  func body(content: Content) -> some View {
    content.task(id: hub.taskId(path: path, body: body)) {
      if let initial {
        action(initial)
      }
      guard hub.isConnected && hub.api.contains(path) else { return }
      do {
        for try await value: T in hub.client.values(path, body) {
          if delayed {
            EventDelayManager.main.execute {
              action(value)
            }
          } else {
            action(value)
          }
        }
      } catch is CancellationError {
        
      } catch {
        print("\(path):", error)
      }
    }
  }
}
extension Hub {
  func taskId(path: String) -> TaskId {
    TaskId(id: id, isConnected: isConnected && api.contains(path))
  }
  func taskId<Body: Hashable>(path: String, body: Body) -> TaskBodyId<Body> {
    TaskBodyId(id: id, isConnected: isConnected && api.contains(path), body: body)
  }
  @MainActor
  struct TaskId: Hashable {
    var id: Hub.ID
    var isConnected: Bool
  }
  @MainActor
  struct TaskBodyId<Body: Hashable>: Hashable {
    var id: Hub.ID
    var isConnected: Bool
    var body: Body
  }
}

@MainActor class EventDelayManager {
  static let main = EventDelayManager()
  var animate = true
  var isWaiting = false
  var pending: [() -> ()] = []
  func execute(_ action: @escaping () -> ()) {
    pending.append(action)
    if !isWaiting {
      isWaiting = true
      Task { try await wait() }
    }
  }
  func wait() async throws {
    try await Task.sleep(for: .milliseconds(animate ? 500 : 3000))
    isWaiting = false
    let pending = self.pending
    self.pending = []
    if animate {
      withAnimation(.home) {
        pending.forEach { $0() }
      }
    } else {
      pending.forEach { $0() }
    }
  }
}
