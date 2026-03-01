//
//  Video encoder view.swift
//  Hub
//
//  Created by Linux on 25.10.25.
//


#if os(macOS) || os(iOS)
import SwiftUI
import AVFoundation

struct VideoEncoderView: View {
  @Observable class Operation: Identifiable {
    var id: URL { file }
    var file: URL
    var progress: Double = 0
    var name: String { file.lastPathComponent }
    var targetName: String {
      file.deletingPathExtension().lastPathComponent
    }
    var size: Int
    var result: URL?
    var error: Bool = false
    var resultSize: Int { Int(result?.fileSize ?? 0) }
    init(file: URL, size: Int) {
      self.file = file
      self.size = size
    }
  }
  @State var selected: Set<Operation.ID> = []
  @State var operations: [Operation] = []
  @State private var sortOrder = [KeyPathComparator(\Operation.name, comparator: .localized)]
  @State private var isRunning = false
  @State private var quality: Float = 0.5
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
        TableRow(file).draggable(VideoTransfer(file: file))
      }
    }.opacity(operations.isEmpty ? 0 : 1).overlay {
      if operations.isEmpty {
        VStack(spacing: 16) {
          VStack {
            Image(systemName: "video").font(.system(size: 88))
              .gradientBlur(radius: 4)
            Text("Video Encoder").font(.title)
            Text("Compress your videos to hevc format").secondary()
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
              Text("Drop videos to start compressing").secondary()
            }
          }.symbolVariant(.fill)
        }.transition(.blurReplace).allowsHitTesting(false)
      }
    }.animation(.smooth, value: operations.isEmpty).dropFiles { (files: [URL], point: CGPoint) -> Bool in
      var content = [URL]()
      for file in files {
        file.contents(array: &content)
      }
      for file in content {
        if file.lastPathComponent.fileType == .video {
          operations.append(Operation(file: file, size: Int(file.fileSize)))
        }
      }
      if !isRunning {
        Task { try await run() }
      }
      return true
    }.safeAreaInset(edge: .top) {
      HStack {
        HStack {
          Text("Quality \(Int(quality * 100))%")
          Slider(value: $quality, in: 0.1...0.9, step: 0.1)
            .frame(maxWidth: 100)
        }
      }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal).secondary()
    }
  }
  struct VideoTransfer: Transferable {
    let file: Operation
    static var transferRepresentation: some TransferRepresentation {
      FileRepresentation(exportedContentType: .quickTimeMovie) { item in
        SentTransferredFile(item.file.result!, allowAccessingOriginalFile: true)
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
        "video.circle"
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
        Image(systemName: icon, variableValue: file.progress).foregroundStyle(color)
          .contentTransition(.symbolEffect(.replace))
        Text(file.name)
      }.progressDraw()
    }
  }
  func run() async throws {
    isRunning = true
    var completed = 0
    for i in 0..<operations.count {
      let operation = operations[i]
      guard operation.result == nil else { return }
      try Task.checkCancellation()
      do {
        let asset = AVAsset(url: operation.file)
        let target = URL.temporaryDirectory.appending(component: UUID().uuidString, directoryHint: .notDirectory).appendingPathExtension(for: .quickTimeMovie)
        try await VideoEncoder().encode(from: asset, to: target, settings: .hevc(quality: quality, size: nil, frameReordering: false)) { total, completed in
          operation.progress = completed.seconds / total.seconds
        }
        operation.result = target
        completed += 1
      } catch {
        operation.error = true
      }
    }
    isRunning = false
    if completed > 0 {
      try await run()
    }
  }
}

#Preview {
  VideoEncoderView()
}
#endif
