//
//  Statistics.swift
//  Hub
//
//  Created by Linux on 14.05.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

struct StatisticsView: View {
  @State private var stats = Statistics.main
  var body: some View {
    HStack {
      ForEach(stats.list) { stats in
        ItemView(stats: stats)
      }
    }.task(id: stats.hasActivity) {
      guard stats.hasActivity else { return }
      do {
        while true {
          try await Task.sleep(for: .seconds(1))
          let now = Date()
          let last = stats.list.max(by: { $0.last < $1.last })!.last
          if now.timeIntervalSince(last) > 3 {
            withAnimation {
              for i in 0..<stats.list.count {
                stats.list[i].first = nil
              }
            }
          }
        }
      } catch { }
    }
  }
  struct ItemView: View {
    let stats: Statistics.Item
    @State private var visible: Bool = false
    @State private var number = false
    @State private var amount: Int = 0
    let scale: CGFloat = 2.0
    var body: some View {
      if stats.first != nil {
        ZStack {
          if visible {
            if number {
              Text(amount, format: .number)
                .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .task(id: stats.completed) {
                  if stats.completed > 1000 {
                    amount = stats.completed
                  } else {
                    withAnimation {
                      amount = stats.completed
                    }
                  }
                }.contentTransition(.numericText()).transition(Transition())
            } else {
              Image(systemName: stats.service.image)
                .font(.system(size: 18 * scale, weight: .semibold))
                .transition(Transition())
            }
          }
        }.frame(minWidth: 56 * scale).frame(height: 56 * scale).background {
          Capsule().stroke(style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round))
            .foregroundStyle(.tertiary)
          Capsule().trim(from: 0, to: visible ? 1 : 0).stroke(style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round))
            .rotation(.degrees(visible ? 0 : -270))
            .animation(visible ? .smooth(duration: 1) : nil, value: visible)
        }.foregroundStyle(.green).task {
          do {
            visible = false
            number = false
            withAnimation {
              visible = true
            }
            try await Task.sleep(for: .seconds(1))
            while true {
              withAnimation {
                number = true
              }
              try await Task.sleep(for: .seconds(10))
              withAnimation {
                number = false
              }
              try await Task.sleep(for: .seconds(3))
            }
          } catch { }
        }.transition(Transition())
      }
    }
  }
  struct Transition: SwiftUI.Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
      content.scaleEffect(phase.isIdentity ? 1 : 0.5).opacity(phase.isIdentity ? 1 : 0)
        .blur(radius: phase == .didDisappear ? 8 : 0)
    }
  }
  struct Testing: View {
    @State private var stats = Statistics.main
    @State private var animating = false
    @State private var toggling = [false, true, false, false, false]
    var body: some View {
      Color.clear.overlay {
        HStack {
          ForEach(stats.list) { stats in
            ItemView(stats: stats)
          }
        }
      }.overlay(alignment: .topLeading) {
        HStack {
          ForEach(0..<5) { index in
            Button {
              toggling[index].toggle()
            } label: {
              Image(systemName: stats.list[index].service.image)
                .foregroundStyle(toggling[index] ? .blue : .primary)
            }
          }
        }
      }.task(id: toggling) {
        guard toggling.contains(true) else { return }
        do {
          while true {
            try await Task.sleep(for: .milliseconds(100))
            for i in 0..<5 {
              if toggling[i] {
                withAnimation {
                  stats.list[i].start()
                  stats.list[i].success()
                }
              }
            }
          }
        } catch { }
      }.frame(maxHeight: .infinity, alignment: .top)
        .padding()
        .task {
          do {
            while true {
              try await Task.sleep(for: .seconds(1))
              let now = Date()
              let last = stats.list.max(by: { $0.last < $1.last })!.last
              if now.timeIntervalSince(last) > 3 {
                withAnimation {
                  for i in 0..<stats.list.count {
                    stats.list[i].first = nil
                  }
                }
              }
            }
          } catch {
            
          }
        }.contentTransition(.numericText())
    }
    func update(_ stat: inout Statistics.Item) {
      if stat.running == 0 {
        stat.start()
      } else {
        if Bool.random() {
          stat.success()
        } else {
          stat.fail()
        }
      }
    }
  }
}

#Preview {
  Color.black.ignoresSafeArea().overlay {
    StatisticsView.Testing().colorScheme(.dark)
  }
}

@MainActor
@Observable class Statistics {
  static let main = Statistics()
  typealias Path = ReferenceWritableKeyPath<Statistics, Item>
  var list: [Item] = AppServices.Service.allCases.map {
    Item(service: $0)
  }
  var hasActivity: Bool {
    list.contains(where: { $0.first != nil })
  }
  @MainActor
  struct Item: Identifiable, Hashable {
    var id: AppServices.Service { service }
    let service: AppServices.Service
    var running = 0
    var completed = 0
    var failed = 0
    var first: Date?
    var last = Date()
    mutating func start() {
      if first == nil {
        first = .now
      }
      last = .now
      running += 1
    }
    mutating func success() {
      last = .now
      running -= 1
      completed += 1
    }
    mutating func fail() {
      last = .now
      running -= 1
      failed += 1
    }
  }
  static func updating<Result>(_ service: AppServices.Service, action: @Sendable () async throws -> Result) async throws -> Result {
    let stats = Statistics.main
    let index = service.rawValue
    stats.list[index].start()
    do {
      let result = try await action()
      stats.list[index].success()
      return result
    } catch {
      stats.list[index].fail()
      throw error
    }
  }
}
