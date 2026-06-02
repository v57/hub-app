//
//  Image encoder view.swift
//  Hub
//
//  Created by Linux on 04.10.25.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import HubUI

enum ImageType: String, Codable, CaseIterable {
  case heic, avif, jpeg, png
  var hasQuality: Bool {
    switch self {
    case .heic, .avif, .jpeg: true
    case .png: false
    }
  }
}

#if os(macOS) || os(iOS) || os(visionOS)

struct ImageEncoderView: View {
  struct Operation: Identifiable {
    let id = UUID()
    var file: URL
    var name: String { targetName }
    var format: ImageType
    var targetName: String {
      file.deletingPathExtension().lastPathComponent + ".\(format.rawValue)"
    }
    var size: Int
    var result: Data?
    var error: Bool = false
    var resultSize: Int { result?.count ?? 0 }
  }
  @State var selected: Set<Operation.ID> = []
  @State var operations: [Operation] = []
  @State private var sortOrder = [KeyPathComparator(\Operation.name, comparator: .localized)]
  @State private var isRunning = false
  @State private var quality: CGFloat = 0.6
  @State private var metadata: Bool = false
  @State private var format: ImageType = .heic
  @State private var currentTask: AnyCancellable?
  @State private var showsSlider = false
  var body: some View {
    Table(of: Operation.self, selection: $selected, sortOrder: $sortOrder) {
      TableColumn("Name", value: \Operation.name) { (file: Operation) in
        NameView(file: file).tint(selected.contains(file.id) ? .white : .blue)
      }
      TableColumn("Size", value: \Operation.size) { (file: Operation) in
        Text(file.size.bytesString).foregroundStyle(.secondary)
      }.width(60)
      TableColumn("Result", value: \Operation.resultSize) { (file: Operation) in
        Text(file.resultSize.bytesString).foregroundStyle(.secondary)
      }.width(60)
    } rows: {
      ForEach(operations) { file in
        TableRow(file).draggable(ImageTransfer(file: file))
      }
    }.opacity(operations.isEmpty ? 0 : 1).overlay {
      if operations.isEmpty {
        Placeholder(image: "photo", title: "Image Encoder", description: "Compress your images to \(format.rawValue) format") {
          Label("Use in your Hub", systemImage: "circle.hexagonpath.fill")
            .foregroundStyle(.red.gradient, .primary)
          Label("Test settings here", systemImage: "hammer")
            .foregroundStyle(.blue, .primary)
          Label("No internet needed", systemImage: "lock.badge.checkmark")
            .foregroundStyle(.green, .primary)
          Label("Drop images to start compressing", systemImage: "arrow.down.app")
        }
      }
    }.animation(.smooth, value: operations.isEmpty).dropFiles { (files: [URL], point: CGPoint) -> Bool in
      add(files: files)
      return true
    }.safeAreaInset(edge: .top) {
      VStack(alignment: .trailing) {
        HStack {
          Text("Convert to")
          Menu(format.rawValue) {
            ForEach(ImageType.allCases, id: \.self) { type in
              Button(type.rawValue) {
                withAnimation {
                  format = type
                }
              }
            }
          }
          Button(metadata ? "including metadata" : "removing metadata") {
            withAnimation {
              metadata.toggle()
            }
          }
          if format.hasQuality {
            Button("at \(Int(quality * 100))% quality") {
              withAnimation {
                showsSlider.toggle()
              }
            }.monospacedDigit().transition(.blurReplace)
          }
        }
        if showsSlider && format.hasQuality {
          Slider(value: $quality.animation(), in: 0.1...0.9, step: 0.1)
            .frame(maxWidth: 200)
            .transition(.blurReplace)
        }
      }.buttonStyle(TabButtonStyle(selected: true))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal).secondary()
    }.safeAreaInset(edge: .bottom) {
      LibraryPickerButton(matching: .images) { url in
        add(files: [url])
      }.buttonStyle(ActionButtonStyle()).padding(.bottom, 4)
    }
  }
  struct ImageTransfer: Transferable {
    let file: Operation
    static var transferRepresentation: some TransferRepresentation {
      DataRepresentation(exportedContentType: .image) { item in
        item.file.result!
      }.suggestedFileName { $0.file.targetName }
    }
  }
  struct NameView: View {
    let file: Operation
    var icon: String {
      if file.error {
        "exclamationmark.octagon.fill"
      } else if file.result != nil {
        "checkmark.circle.fill"
      } else {
        "clock.fill"
      }
    }
    var color: Color {
      if file.error {
        .red
      } else if file.result != nil {
        .green
      } else {
        .gray
      }
    }
    var body: some View {
      HStack {
        Image(systemName: icon).foregroundStyle(color)
          .contentTransition(.symbolEffect(.replace))
        Text(file.name)
      }
    }
  }
  func add(files: [URL]) {
    var content = [URL]()
    for file in files {
      file.contents(array: &content)
    }
    for file in content {
      if file.lastPathComponent.fileType == .image {
        operations.append(Operation(file: file, format: format, size: Int(file.fileSize), result: nil))
      }
    }
    if !isRunning {
      currentTask = Task {
        await run()
      }.cancellable()
    }
  }
  func run() async {
    guard !isRunning else { return }
    isRunning = true
    var completed = 0
    
    do {
      for i in 0..<operations.count {
        let operation = operations[i]
        guard operation.result == nil else { continue }
        try Task.checkCancellation()
        do {
          operations[i].result = try await operation.file
            .image(format: operation.format.rawValue, quality: quality, metadata: metadata)
          completed += 1
        } catch {
          operations[i].error = true
          print(error)
        }
      }
    } catch { }
    isRunning = false
    if completed > 0 {
      await run()
    }
  }
}

#Preview {
  ImageEncoderView().test()
}
#endif

extension URL {
  func image(format: String, quality: CGFloat, metadata: Bool) async throws -> Data {
    try await Task.detached {
      try Data(contentsOf: self).image(format: format, quality: quality, metadata: metadata)
    }.value
  }
}
