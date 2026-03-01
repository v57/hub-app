//
//  Image encoder view.swift
//  Hub
//
//  Created by Linux on 04.10.25.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

enum ImageType: String, Codable, CaseIterable {
  case heic, avif, jpeg, png
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
        VStack(spacing: 16) {
          VStack {
            Image(systemName: "photo").font(.system(size: 88))
              .gradientBlur(radius: 4)
            Text("Image Encoder").font(.title)
            Text("Compress your images to \(format.rawValue) format").secondary()
          }
          VStack(alignment: .center, spacing: 4) {
            HStack(spacing: 4) {
              Image(systemName: "circle.hexagonpath.fill").frame(width: 16)
                .foregroundStyle(.red.gradient)
              Text("Use in your Hub").font(.caption2)
            }
            HStack(spacing: 4) {
              Image(systemName: "hammer").frame(width: 16)
                .foregroundStyle(.blue)
              Text("Test settings here").font(.caption2)
            }
            HStack(spacing: 4) {
              Image(systemName: "lock.badge.checkmark").frame(width: 16)
                .foregroundStyle(.green)
              Text("No internet needed").font(.caption2)
            }
            HStack(spacing: 4) {
              Image(systemName: "arrow.down.app").frame(width: 16)
              Text("Drop images to start compressing").secondary()
            }
          }.symbolVariant(.fill)
        }.transition(.blurReplace).allowsHitTesting(false)
      }
    }.animation(.smooth, value: operations.isEmpty).dropFiles { (files: [URL], point: CGPoint) -> Bool in
      add(files: files)
      return true
    }.safeAreaInset(edge: .top) {
      HStack {
        Picker("Output Format", selection: $format) {
          ForEach(ImageType.allCases, id: \.self) {
            Text($0.rawValue).id($0)
          }
        }
        Toggle("Keep metadata", isOn: $metadata)
        HStack {
          Text("Quality \(Int(quality * 100))%")
          Slider(value: $quality, in: 0.1...0.9, step: 0.1)
            .frame(maxWidth: 100)
        }
      }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal).secondary()
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
        }
      }
    } catch { }
    isRunning = false
    print(completed, isRunning)
    if completed > 0 {
      await run()
    }
  }
}

#Preview {
  ImageEncoderView()
}
#endif

extension URL {
  func image(format: String, quality: CGFloat, metadata: Bool) async throws -> Data {
    try await Task.detached {
      try Data(contentsOf: self).image(format: format, quality: quality, metadata: metadata)
    }.value
  }
}
