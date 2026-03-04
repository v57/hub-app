//
//  Storage.swift
//  Hub
//
//  Created by Linux on 13.07.25.
//

import SwiftUI
import UniformTypeIdentifiers

struct StorageView: View {
  @Environment(Hub.self) var hub
  @State var list = FileList(count: 0, files: [], directories: [])
  @State var selected: Set<String> = []
  @State var path: String = ""
  var directories: [FileInfo] {
    uploadManager.directories(for: hub, at: path, with: list.directories)
      .map { FileInfo(name: $0, size: 0, lastModified: nil) }
      .sorted(using: sortOrder)
  }
  var files: [FileInfo] {
    uploadManager.files(for: hub, at: path, with: list.files)
      .sorted(using: sortOrder)
  }
  @State var uploadManager = UploadManager.main
  @State private var sortOrder = [KeyPathComparator(\FileInfo.name, comparator: .localized)]
  var body: some View {
#if !os(tvOS)
    Table(of: FileInfo.self, selection: $selected, sortOrder: $sortOrder) {
      TableColumn("Name", value: \FileInfo.name) { (file: FileInfo) in
        NameView(file: file, path: path).tint(selected.contains(file.name) ? .white : .blue).environment(hub)
      }
      TableColumn("Size", value: \FileInfo.size) { (file: FileInfo) in
        Text(file.size.bytesString)
          .foregroundStyle(.secondary)
      }.width(60)
      TableColumn("Last Modified", value: \FileInfo.lastModified) { (file: FileInfo) in
        if let date = file.lastModified {
          Text(date, format: .dateTime).foregroundStyle(.secondary)
        } else {
          Text("")
        }
      }.width(110)
    } rows: {
      TableRow(FileInfo(name: path.isEmpty ? "$\(hub.settings.name)" : "/\(path)", size: 0, lastModified: nil))
      ForEach(directories, id: \.self) { file in
        TableRow(file).draggable(DirectoryTransfer(hub: hub, name: file.name))
      }
      ForEach(files) { file in
        TableRow(file).draggable(FileInfoTransfer(hub: hub, file: file))
      }
    }.contextMenu(forSelectionType: String.self) { (files: Set<String>) in
      if files.count == 1, let file = files.first, file.last != "/" {
        Button("Copy temporary link", systemImage: "link") {
          Task {
            let link: String = try await hub.client.send("s3/read", path + file)
            link.copyToClipboard()
          }
        }
      }
      Button("Delete", systemImage: "trash", role: .destructive) {
        Task { await remove(files: Array(files)) }
      }.keyboardShortcut(.delete)
    } primaryAction: { files in
      if files.count == 1, let file = files.first, file.hasSuffix("/") {
        guard !file.isEmpty else { return }
        if file.hasPrefix("/") {
          path = path.parentDirectory
        } else {
          path += file
        }
      }
    }.toolbar {
      if !path.isEmpty {
        Button("Back", systemImage: "chevron.left") {
          path = path.parentDirectory
        }
      }
      if selected.count > 0 {
        Button("Delete Selected", systemImage: "trash", role: .destructive) {
          Task {
            await remove(files: Array(selected))
          }
        }.keyboardShortcut(.delete)
      }
    }.dropDestination { (files: [URL], point: CGPoint) -> Bool in
      add(files: files)
      return true
    }.navigationTitle("Storage").hubStream("s3/list", path, to: $list)
      .contentTransition(.symbolEffect(.replace))
      .progressDraw()
#endif
  }
  func add(files: [URL]) {
    uploadManager.upload(files: files, directory: path, to: hub)
  }
  func remove(files: [String]) async {
    do {
      for file in files {
        try await hub.client.send("s3/delete", path + file)
      }
    } catch {
      print(error)
    }
  }
  // MARK: File name view
  struct NameView: View {
    let file: FileInfo
    let path: String
    var body: some View {
      if file.name.first == "/" {
        HStack(spacing: 0) {
          Image(systemName: "chevron.left")
            .frame(minWidth: 25)
          Text(name.dropFirst())
        }.foregroundStyle(.tint).fontWeight(.medium)
      } else if file.name.first == "$" {
        HStack(spacing: 0) {
          Image(systemName: "display")
            .frame(minWidth: 25)
          Text(name.dropFirst())
        }.foregroundStyle(.tint).fontWeight(.medium)
      } else {
        HStack(spacing: 0) {
          IconView(file: file, path: path)
            .foregroundStyle(.tint)
            .frame(minWidth: 25)
          Text(name).contentTransition(.numericText()).animation(.smooth, value: name)
        }
      }
    }
    struct IconView: View {
      @Environment(Hub.self) private var hub
      @State private var uploadManager = UploadManager.main
      
      let file: FileInfo
      let path: String
      var body: some View {
        let progress = uploadManager.progress(for: hub, at: path + file.name)
        let isCompleted: Bool = progress == 1
        Image(systemName: isCompleted ? "checkmark" : icon, variableValue: progress)
          .symbolVariant(progress != nil ? .circle : .fill)
      }
      var icon: String {
        file.isDirectory ? "folder" : fileIcon
      }
      var fileIcon: String {
        switch file.name.fileType {
        case .image: "photo"
        case .video: "video"
        case .audio: "speaker.wave.2"
        case .document: "document"
        }
      }
    }
    var name: String {
      file.isDirectory ? String(file.name.dropLast(1)) : file.name
    }
  }
}


// MARK: Downloads/Uploads
@Observable @MainActor
final class UploadManager: Sendable {
  static let main = UploadManager()
  private var tasks = [Hub.ID: PathContent]()
  private var uploadingSize: Int64 = 0
  private var running = Set<PendingTask>()
  private var pending = [PendingTask]()
  private var completed = Set<PendingTask>()
  private let session: URLSession
  private let delegate: Delegate
  private init() {
    let delegate = Delegate()
    self.delegate = delegate
    session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: .main)
  }
  // MARK: Download
  func download(file: FileInfo, from hub: Hub) async throws -> URL {
    let link: URL = try await hub.client.send("s3/read", file.name)
    let progress = ObservableProgress()
    progress.progress.total = Int64(file.size)
    set(path: file.name, hub: hub, task: progress)
    defer {
      Task {
        try await Task.sleep(for: .seconds(1))
        remove(path: file.name, hub: hub)
      }
    }
    let url = URL.temporaryDirectory.appending(component: UUID().uuidString, directoryHint: .notDirectory)
    try await session.download(from: link, to: url, delegate: delegate, progress: progress)
    return url
  }
  func download(directory name: String, from hub: Hub) async throws -> URL {
    let manager = FileManager.default
    let files: [FileInfo] = try await hub.client.send("s3/read/directory", name)
    let root = URL.temporaryDirectory.appending(component: UUID().uuidString, directoryHint: .isDirectory)
    let progresses = files.map { (file: FileInfo) -> ObservableProgress in
      let progress = ObservableProgress()
      progress.progress.total = Int64(file.size)
      set(path: file.name, hub: hub, task: progress)
      return progress
    }
    defer {
      Task {
        try await Task.sleep(for: .seconds(1))
        files.forEach { file in remove(path: file.name, hub: hub) }
      }
    }
    for (file, progress) in zip(files, progresses) {
      let link: URL = try await hub.client.send("s3/read", file.name)
      let path = file.name.components(separatedBy: "/").dropFirst().joined(separator: "/")
      let target = root.appending(path: path, directoryHint: .notDirectory)
      try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await session.download(from: link, to: target, delegate: delegate, progress: progress)
    }
    return root
  }
  // MARK: Upload
  @discardableResult
  func upload(files: [URL], directory: String, to hub: Hub) -> UploadSession {
    let session = UploadSession()
    session.tasks += 1
    defer { session.tasks -= 1 }
    for url in files {
      if url.hasDirectoryPath {
        var content = [URL]()
        url.contents(array: &content)
        let prefix = url.path(percentEncoded: false).count - url.lastPathComponent.count - 1
        session.tasks += content.count
        for url in content {
          let name = url.path(percentEncoded: false)
          let file = UploadingFile(target: directory + String(name.suffix(name.count - prefix)), content: url)
          let task = ObservableProgress()
          task.progress.total = url.fileSize
          set(path: file.target, hub: hub, task: task)
          session.files.append(file)
          upload(file: file, with: task, to: hub) { result in
            session.completeTask(result: result)
          }
        }
      } else {
        session.tasks += 1
        let file = UploadingFile(target: directory + url.lastPathComponent, content: url)
        let task = ObservableProgress()
        task.progress.total = url.fileSize
        session.files.append(file)
        set(path: file.target, hub: hub, task: task)
        
        upload(file: file, with: task, to: hub) { result in
          session.completeTask(result: result)
        }
      }
    }
    return session
  }
  @Observable
  class UploadSession {
    var tasks: Int = 0
    var lastError: Error?
    var files: [UploadingFile] = []
    func completeTask(result: Result<Void, Error>) {
      print("Upload completed", result)
      do {
        try result.get()
      } catch {
        lastError = error
      }
      tasks -= 1
    }
  }
  private func upload(file: UploadingFile, with task: ObservableProgress, to hub: Hub, completion: @escaping (Result<Void, Error>) -> Void) {
    let task = PendingTask(hub: hub, file: file, progress: task, completion: completion)
    pending.append(task)
    if running.isEmpty {
      nextPending()
    }
  }
  private func nextPending() {
    guard !pending.isEmpty else { return }
    guard uploadingSize < 10_000_000 else { return }
    let task = pending.removeFirst()
    let total = task.progress.progress.total
    uploadingSize += total
    running.insert(task)
    Task {
      try? await task.start()
      uploadingSize -= total
      running.remove(task)
      nextPending()
      completed.insert(task)
      if running.isEmpty {
        try await Task.sleep(for: .seconds(1))
        completed.forEach { task in
          remove(path: task.file.target, hub: task.hub)
        }
        completed = []
      }
    }
    nextPending()
  }
  // MARK: Delegate
  @MainActor
  final fileprivate class Delegate: NSObject, @preconcurrency URLSessionDownloadDelegate {
    struct Task: Sendable {
      let upload: ObservableProgress
      var target: URL?
      let continuation: CheckedContinuation<Void, Error>
    }
    var tasks = [URLSessionTask: Task]()
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
      guard let task = tasks[downloadTask] else { return }
      guard let target = task.target else { return }
      try! FileManager.default.moveItem(at: location, to: target)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      if let error {
        tasks[task]?.continuation.resume(throwing: error)
        tasks[task] = nil
      } else {
        tasks[task]?.continuation.resume()
        tasks[task] = nil
      }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
      guard let task = tasks[task]?.upload else { return }
      guard totalBytesExpectedToSend > 0 else { return }
      let progress = StaticProgress(sent: totalBytesSent, total: totalBytesExpectedToSend)
      task.set(progress: progress)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
      guard let task = tasks[downloadTask]?.upload else { return }
      let progress = StaticProgress(sent: totalBytesWritten, total: totalBytesExpectedToWrite)
      task.set(progress: progress)
    }
  }
  // MARK: Pending task
  private struct PendingTask: Hashable {
    let hub: Hub, file: UploadingFile, progress: ObservableProgress
    let completion: (Result<Void, Error>) -> Void
    @MainActor
    func start() async throws {
      do {
        let url: URL = try await hub.client.send("s3/write", file.target)
        let manager = UploadManager.main
        _ = try await manager.session.upload(file: file.content, to: url, delegate: manager.delegate, progress: progress)
        let parent = file.target.parentDirectory
        try await hub.client.send("s3/updated", parent)
        if !parent.isEmpty {
          try await hub.client.send("s3/updated", parent.parentDirectory)
        }
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
    func hash(into hasher: inout Hasher) {
      progress.hash(into: &hasher)
    }
    static func ==(l: Self, r: Self) -> Bool {
      l.progress === r.progress
    }
  }
  // MARK: Path content controls
  func directories(for hub: Hub, at path: String, with current: [String]) -> [String] {
    let set = Set(current)
    var current = current
    let components = path.components(separatedBy: "/")
    var iterator = components.makeIterator()
    tasks[hub.id]?.resolve(path: &iterator)?.directories.sorted().forEach { key in
      if !set.contains(key) {
        current.append(key)
      }
    }
    return current
  }
  func files(for hub: Hub, at path: String, with current: [FileInfo]) -> [FileInfo] {
    let set = Set(current.map { $0.name })
    var current = current
    let components = path.components(separatedBy: "/")
    var iterator = components.makeIterator()
    tasks[hub.id]?.resolve(path: &iterator)?.files.sorted().forEach { key in
      if !set.contains(key) {
        current.append(FileInfo(name: key, size: 0, lastModified: nil))
      }
    }
    return current
  }
  private func set(path: String, hub: Hub, task: ObservableProgress) {
    let components = path.components(separatedBy: "/")
    var iterator = components.makeIterator()
    var tasks = tasks[hub.id] ?? .directory([:])
    tasks.set(path: &iterator, task: task)
    self.tasks[hub.id] = tasks
  }
  private func remove(path: String, hub: Hub) {
    let components = path.components(separatedBy: "/")
    var iterator = components.makeIterator()
    guard var tasks = tasks[hub.id] else { return }
    if tasks.remove(path: &iterator) {
      tasks = .directory([:])
    }
    self.tasks[hub.id] = tasks
  }
  func progress(for hub: Hub, paths: [String], defaultValue: Double) -> Double {
    var total: Double = 0
    for path in paths {
      total += progress(for: hub, at: path) ?? defaultValue
    }
    return total / Double(paths.count)
  }
  func progress(for hub: Hub, at path: String) -> Double? {
    let components = path.components(separatedBy: "/")
    var iterator = components.makeIterator()
    return tasks[hub.id]?.progress(path: &iterator)
  }
  // MARK: Path content
  private enum PathContent: Sendable {
    case file(ObservableProgress)
    case directory([String: PathContent])
    init(path: inout IndexingIterator<[String]>, task: ObservableProgress) {
      if let next = path.next() {
        self = .directory([next: PathContent(path: &path, task: task)])
      } else {
        self = .file(task)
      }
    }
    mutating func set(path: inout IndexingIterator<[String]>, task: ObservableProgress) {
      if let next = path.next() {
        switch self {
        case .file: break
        case .directory(var dictionary):
          if var value = dictionary[next] {
            value.set(path: &path, task: task)
            dictionary[next] = value
          } else {
            dictionary[next] = PathContent(path: &path, task: task)
          }
          self = .directory(dictionary)
        }
      } else {
        self = .file(task)
      }
    }
    mutating func remove(path: inout IndexingIterator<[String]>) -> Bool {
      switch self {
      case .file: return true
      case .directory(var dictionary):
        guard let next = path.next() else { return false }
        guard var value = dictionary[next] else { return false }
        if value.remove(path: &path) {
          dictionary[next] = nil
          if dictionary.count == 0 {
            return true
          } else {
            self = .directory(dictionary)
            return false
          }
        } else {
          dictionary[next] = value
          self = .directory(dictionary)
        }
        return false
      }
    }
    func progress(path: inout IndexingIterator<[String]>) -> Double? {
      switch self {
      case .file(let task): return task.progress.progress
      case .directory(let dictionary):
        if let p = path.next(), !p.isEmpty {
          return dictionary[p]?.progress(path: &path)
        } else {
          var progress = StaticProgress()
          var edited = false
          self.progress(progress: &progress, edited: &edited)
          guard edited else { return nil }
          return progress.progress
        }
      }
    }
    func progress(progress: inout StaticProgress, edited: inout Bool) {
      switch self {
      case .file(let task):
        progress.sent += task.progress.sent
        progress.total += task.progress.total
        edited = true
      case .directory(let dictionary):
        dictionary.values.forEach { $0.progress(progress: &progress, edited: &edited) }
      }
    }
    func resolve(path: inout IndexingIterator<[String]>) -> PathContent? {
      guard let next = path.next(), !next.isEmpty else { return self }
      switch self {
      case .file:
        return nil
      case .directory(let dictionary):
        return dictionary[next]?.resolve(path: &path)
      }
    }
    var directories: [String] {
      switch self {
      case .file: return []
      case .directory(let dictionary):
        return dictionary.compactMap { (key: String, t: PathContent) -> String? in
          switch t {
          case .directory: return key + "/"
          case .file: return nil
          }
        }
      }
    }
    var files: [String] {
      switch self {
      case .file: return []
      case .directory(let dictionary):
        return dictionary.compactMap { (key: String, t: PathContent) -> String? in
          switch t {
          case .file: return key
          case .directory: return nil
          }
        }
      }
    }
  }
}

struct StaticProgress: Hashable, Sendable {
  var sent: Int64 = 0
  var total: Int64 = 0
  var progress: Double {
    guard total > 0 else { return 0 }
    return Double(sent) / Double(total)
  }
}

private extension URLSession {
  @MainActor
  func download(from: URL, to: URL, delegate: UploadManager.Delegate, progress: ObservableProgress) async throws {
    try await withCheckedThrowingContinuation { continuation in
      let downloadTask = downloadTask(with: URLRequest(url: from))
      delegate.tasks[downloadTask] = .init(upload: progress, target: to, continuation: continuation)
      downloadTask.resume()
    }
  }
  @MainActor
  func upload(file: URL, to: URL, delegate: UploadManager.Delegate, progress: ObservableProgress) async throws {
    try await withCheckedThrowingContinuation { continuation in
      var request = URLRequest(url: to)
      request.httpMethod = "PUT"
      let uploadTask = uploadTask(with: request, fromFile: file)
      delegate.tasks[uploadTask] = .init(upload: progress, continuation: continuation)
      uploadTask.resume()
    }
  }
}

@Observable
final class ObservableProgress: @unchecked Sendable, Hashable {
  var progress = StaticProgress()
  @ObservationIgnored
  private var pendingProgress: StaticProgress?
  @ObservationIgnored
  private var pendingTask: Task<Void, Error>?
  func set(progress: StaticProgress) {
    if pendingTask == nil {
      self.progress = progress
      pendingTask = Task {
        while true {
          try await Task.sleep(for: .milliseconds(200))
          if let pendingProgress {
            self.progress = pendingProgress
            self.pendingProgress = nil
          } else {
            break
          }
        }
        pendingTask = nil
      }
    } else {
      self.pendingProgress = progress
    }
  }
  func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }
  static func == (l: ObservableProgress, r: ObservableProgress) -> Bool {
    l === r
  }
}

struct UploadingFile: Hashable {
  let target: String
  let content: URL
}

struct FileList: Decodable {
  let count: Int
  var files: [FileInfo]
  var directories: [String]
}
struct FileInfo: Identifiable, Hashable, Decodable {
  var id: String { name }
  let name: String
  var isDirectory: Bool { name.last == "/" }
  var ext: String {
    isDirectory ? "" : String(name.split { $0 == "." }.last!)
  }
  let size: Int
  let lastModified: Date?
}

extension Optional: @retroactive Comparable where Wrapped == Date {
  public static func < (lhs: Optional, rhs: Optional) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs < rhs
  }
}

// MARK: Transferable
struct FileInfoTransfer: Transferable {
  let hub: Hub
  let file: FileInfo
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation<Self>(exportedContentType: .data) { file in
      try await SentTransferredFile(file.download(), allowAccessingOriginalFile: false)
    }.suggestedFileName { $0.file.name }
  }
  func download() async throws -> URL {
    do {
      return try await UploadManager.main.download(file: file, from: hub)
    } catch {
      print(error)
      throw error
    }
  }
}

struct DirectoryTransfer: Transferable {
  let hub: Hub
  let name: String
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation<Self>(exportedContentType: .folder) { file in
      try await SentTransferredFile(file.download(), allowAccessingOriginalFile: false)
    }.suggestedFileName { String($0.name.dropLast(1)) }
  }
  func download() async throws -> URL {
    do {
      return try await UploadManager.main.download(directory: name, from: hub)
    } catch {
      print(error)
      throw error
    }
  }
}

// MARK: Extensions
extension URL {
  func contents(array: inout [URL]) {
    if hasDirectoryPath {
      let content = (try? FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil)) ?? []
      for url in content {
        url.contents(array: &array)
      }
    } else {
      array.append(self)
    }
  }
  var fileExists: Bool {
    FileManager.default.fileExists(atPath: path(percentEncoded: false))
  }
  var fileSize: Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path(percentEncoded: false))[FileAttributeKey.size] as? Int64) ?? 0
  }
  func delete() {
    try? FileManager.default.removeItem(at: self)
  }
}
extension Int {
  var bytesString: String {
    guard self > 0 else { return "" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(self))
  }
}
extension String {
  var parentDirectory: String {
    guard !isEmpty else { return self }
    let c = components(separatedBy: "/")
    let d = c.prefix(c.last == "" ? c.count - 2 : c.count - 1).joined(separator: "/")
    return d.isEmpty ? d : d + "/"
  }
  enum FileType {
    case image, video, audio, document
  }
  var fileType: FileType {
    switch components(separatedBy: ".").last?.lowercased() {
    case "png", "jpg", "jpeg", "heic", "avif": .image
    case "mp4", "mov", "mkv", "avi": .video
    case "wav", "ogg", "acc", "m4a", "mp3": .audio
    default: .document
    }
  }
}

extension View {
  @ViewBuilder
  func progressDraw() -> some View {
    if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *, visionOS 26.0, *) {
      self.symbolVariableValueMode(.draw)
    } else {
      self
    }
  }
}

// MARK: Preview
#Preview {
  StorageView().test()
}
