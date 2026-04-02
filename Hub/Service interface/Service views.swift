//
//  UI Elements.swift
//  Hub
//
//  Created by Dmitry Kozlov on 6/7/25.
//

import SwiftUI
import Combine
import HubService

struct InterfaceData {
  var string: [String: String]
}

@Observable
class ServiceApp {
  var app = AppInterface()
  var data = [String: AnyCodable]()
  var lists = [String: [NestedList]]()
  struct List: Identifiable {
    var id: String
    var string: [String: AnyCodable]
  }
  init() {
    
  }
  @MainActor
  func sync(hub: Hub, path: String, context: Hub.Context? = nil) async {
    do {
      print("syncing", path)
      for try await event: AppInterface in hub.client.values(path, context: context) {
        if let header = event.header {
          self.app.header = header
        }
        if let body = event.body {
          self.app.body = body
        }
        if let data = event.data {
          self.data = data
        }
      }
    } catch {
      print(error)
    }
  }
  func store(_ value: AnyCodable, for key: String, nested: NestedList?) {
    if let nested {
      if nested.data?[key] != value {
        nested.data?[key] = value
      }
    } else if data[key] != value {
      data[key] = value
    }
  }
  func reset() {
    app = AppInterface()
    data = [:]
    lists = [:]
  }
}



extension Element: @retroactive View {
  @MainActor
  struct AppState: DynamicProperty {
    @Environment(ServiceApp.self) var app
    @Environment(NestedList.self) var nested: NestedList?
    @Environment(Hub.self) var hub
    @Environment(\.serviceContext) var context
    var name: String { app.app.header?.name ?? "Services" }
    func translate(_ value: String) -> String? {
      value.staticText ?? self.string(String(value.dropFirst()))
    }
    func string(_ value: String) -> String? {
      nested?.data?[value]?.string ?? app.data[value]?.string
    }
    func stringBinding(_ value: String, defaultValue: String) -> Binding<String> {
      Binding {
        self.string(value) ?? defaultValue
      } set: { newValue in
        app.store(.string(newValue), for: value, nested: nested)
      }
    }
    func double(_ value: String) -> Double? {
      nested?.data?[value]?.double ?? app.data[value]?.double
    }
    func doubleBinding(_ value: String, defaultValue: Double) -> Binding<Double> {
      Binding {
        self.double(value) ?? defaultValue
      } set: { newValue in
        app.store(.double(newValue), for: value, nested: nested)
      }
    }
    func send<Output: Decodable>(_ path: String) async throws -> Output {
      try await hub.client.send(path, context: context)
    }
    func send(_ path: String) async throws {
      try await hub.client.send(path, context: context)
    }
    func send<Body: Encodable>(_ path: String, _ body: Body?) async throws {
      try await hub.client.send(path, body, context: context)
    }
    func send<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) async throws -> Output {
      try await hub.client.send(path, body, context: context)
    }
    func store(_ value: AnyCodable, for key: String) {
      app.store(value, for: key, nested: nested)
    }
    func perform(action: Action) async throws {
      try await action.perform(hub: hub, app: app, nested: nested, context: context)
    }
    func perform(action: Action, customValues: (inout [String: AnyCodable]) -> Void) async throws {
      try await action.perform(hub: hub, app: app, nested: nested, context: context, customValues: customValues)
    }
    func upload(files: [URL]) -> UploadManager.UploadSession {
      UploadManager.main.upload(files: files, directory: name + "/", to: hub, context: context)
    }
  }
  
  @ViewBuilder
  public var body: some View {
    switch self {
    case .text(let a): TextView(value: a)
    case .textField(let a): TextFieldView(value: a)
    case .button(let a): ButtonView(value: a)
    case .list(let a): ListView(value: a)
    case .picker(let a): PickerView(value: a)
    case .cell(let a): CellView(value: a)
    case .files(let a): FilesView(value: a)
    case .fileOperation(let a): FileOperationView(value: a)
    case .spacer: SwiftUI.Spacer()
    case .hstack(let a): HStackView(value: a)
    case .vstack(let a): VStackView(value: a)
    case .zstack(let a): ZStackView(value: a)
    case .progress(let a): ProgressView(value: a)
    case .slider(let a): SliderView(value: a)
    @unknown default: UnknownView()
    }
  }
  struct TextView: View {
    let value: Text
    let state = AppState()
    var body: some View {
      if let text = state.translate(value.value) {
        if value.secondary {
          SwiftUI.Text(text).textSelection().secondary()
        } else {
          SwiftUI.Text(text).textSelection()
        }
      }
    }
  }
  struct ProgressView: View {
    let value: Progress
    let state = AppState()
    
    func progress(current: Double) -> Double {
      let range = range
      let current = min(max(range.lowerBound, current), range.upperBound)
      return (current - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    var range: Range<Double> {
      return value.min..<max(value.min, value.max)
    }
    var body: some View {
      if let current = state.double(value.value) {
        let progress = progress(current: current)
        SwiftUI.ZStack {
          Circle().trim(from: 0, to: 1)
            .stroke(.red.opacity(0.2), lineWidth: 3)
          Circle().trim(from: 0, to: progress)
            .rotation(.degrees(-90))
            .stroke(.red.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .animation(.smooth, value: progress)
        }.frame(width: 18, height: 18)
      }
    }
  }
  struct UnknownView: View {
    var body: some View {
      Image(systemName: "questionmark.circle.dashed")
        .foregroundStyle(.tertiary)
    }
  }
  struct HStackView: View {
    let value: HStack
    var body: some View {
      SwiftUI.HStack(spacing: value.spacing?.cg) {
        ForEach(value.content) { $0 }
      }
    }
  }
  struct VStackView: View {
    let value: VStack
    var body: some View {
      SwiftUI.VStack(spacing: value.spacing?.cg) {
        ForEach(value.content) { $0 }
      }
    }
  }
  struct ZStackView: View {
    let value: ZStack
    var body: some View {
      SwiftUI.ZStack {
        ForEach(value.content) { $0 }
      }
    }
  }
  struct TextFieldView: View {
    let value: TextField
    @State var text: String = ""
    @State var disableUpdates = true
    let state = AppState()
    var body: some View {
      let data = state.string(value.value)
      SwiftUI.TextField(value.placeholder, text: $text)
        .task(id: data) {
          if let data, data != text {
            disableUpdates = true
            text = data
          }
        }.task(id: text) {
          if !disableUpdates {
            state.app.store(.string(text), for: value.value, nested: state.nested)
            if let action = value.action {
              try? await state.perform(action: action)
            }
          } else {
            disableUpdates = false
          }
        }
    }
  }
  struct PickerView: View {
    let value: Picker
    @State var selected: String = ""
    let state = AppState()
    var body: some View {
      SwiftUI.Picker("", selection: state.stringBinding(value.selected, defaultValue: "")) {
        ForEach(value.options, id: \.self) { value in
          SwiftUI.Text(value).tag(value)
        }
      }
    }
  }
  struct SliderView: View {
    let value: Slider
    let state = AppState()
    var range: ClosedRange<Double> {
      value.min...max(value.min, value.max)
    }
    var body: some View {
      let v = state.doubleBinding(value.value, defaultValue: value.max)
      if let step = value.step {
        SwiftUI.Slider(value: v, in: range, step: step).frame(maxWidth: 150)
      } else {
        SwiftUI.Slider(value: v, in: range).frame(maxWidth: 150)
      }
    }
  }
  struct ButtonView: View {
    let value: Button
    let state = AppState()
    var body: some View {
      if let title = state.translate(value.title) {
        AsyncButton(title) {
          try await state.perform(action: value.action)
        }
      }
    }
  }
  struct ListView: View {
    let value: List
    @Environment(ServiceApp.self) var app
    var body: some View {
      if let list = app.lists[value.data] {
        SwiftUI.ForEach(list) { data in
          SwiftUI.HStack {
            value.content
          }.environment(data)
        }
      }
    }
  }
  struct CellView: View {
    let value: Cell
    var body: some View {
      SwiftUI.VStack(alignment: .leading) {
        value.title?.secondary()
        value.subtitle
      }
    }
  }
  struct FilesView: View {
    let value: Files
    let state = AppState()
    @State private var files = [String]()
    @State private var session: UploadManager.UploadSession?
    var path: String { state.name }
    var body: some View {
      RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.1))
        .frame(height: 80).overlay {
          SwiftUI.List(files, id: \.self) { name in
            StorageView.NameView(file: FileInfo(name: name, size: 0, lastModified: nil), path: path)
          }.environment(UploadManager.main).progressDraw()
          if files.isEmpty {
            SwiftUI.VStack {
              SwiftUI.Text("Drop files").foregroundStyle(.secondary)
              value.title
            }
          }
        }.dropFiles { (files: [URL], point: CGPoint) -> Bool in
          self.files = files.map(\.lastPathComponent)
          session = state.upload(files: files)
          return true
        }.onChange(of: session?.tasks == 0) {
          guard let session, session.tasks == 0 else { return }
          let files = session.files.map(\.target)
          Task {
            var links = [AnyCodable]()
            for path in files {
              let url: URL = try await state.send("s3/read", path)
              links.append(.string(url.absoluteString))
            }
            state.store(.array(links), for: value.value)
            try await state.perform(action: value.action)
          }
        }
    }
  }
  struct FileOperationView: View {
    let value: FileOperation
    @State private var files = [String]()
    @State private var session: UploadManager.UploadSession?
    @State private var processed = 0
    @State private var isClearing = false
    @State private var failed = Set<String>()
    let state = AppState()
    var path: String { state.name + "/" }
    var body: some View {
      RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.1))
        .frame(height: 140).overlay {
          if files.isEmpty {
            SwiftUI.VStack {
              SwiftUI.Text("Drop files")
                .foregroundStyle(.secondary)
              value.title
            }.transition(.blurReplace)
          } else if let session {
            FileTaskStatus(session: session, files: session.files.map(\.target), uploaded: files.count - session.tasks, processed: processed, target: path + "Output/", isClearing: $isClearing).transition(.blurReplace)
          }
        }.animation(.smooth, value: session?.tasks)
        .animation(.smooth, value: processed)
        .dropFiles { (files: [URL], point: CGPoint) -> Bool in
          withAnimation {
            isClearing = false
            self.files = files.map(\.lastPathComponent)
            processed = 0
            session = state.upload(files: files)
          }
          return true
        }.onChange(of: session?.tasks == 0) {
          guard let session, session.tasks == 0 else { return }
          let files = session.files.map(\.target)
          Task {
            for path in files {
              do {
                let from: String = try await state.send("s3/read", path)
                let target = target(from: path)
                let to: String = try await state.send("s3/write", target)
                try await state.perform(action: value.action) { data in
                  data["from"] = .string(from)
                  data["to"] = .string(to)
                }
              } catch {
                failed.insert(path)
              }
              processed += 1
            }
          }
        }.buttonStyle(.plain)
    }
    func target(from path: String) -> String {
      var result = path.parentDirectory + "Output/" + path.components(separatedBy: "/").last!
      guard let v = value.format, let format = state.translate(v) else { return result }
      result.fileExtension = format
      return result
    }
  }
}
extension String {
  var staticText: String? {
    starts(with: "$") ? nil : self
  }
  fileprivate var fileExtension: String {
    get { components(separatedBy: ".").last ?? "" }
    set {
      var c = components(separatedBy: ".")
      if c.count > 1 {
        c[c.count - 1] = newValue
        self = c.joined(separator: ".")
      } else {
        self += ".\(newValue)"
      }
    }
  }
}
extension Double {
  var cg: CGFloat { CGFloat(self) }
}

@Observable
class NestedList: Identifiable {
  var data: [String: AnyCodable]?
  init(data: [String : AnyCodable]? = nil) {
    self.data = data
  }
}

struct ServiceView: View {
  @Environment(Hub.self) private var hub
  @State private var app = ServiceApp()
  let header: Hub.AppHeader
  @State private var context = Hub.Context()
  var body: some View {
    GeometryReader { view in
      ScrollView {
        VStack {
          if let body = app.app.body {
            ForEach(body) { element in
              element
            }
          }
        }.frame(minHeight: view.size.height)
      }
    }.safeAreaPadding().toolbar {
      ServiceProvider.Picker(path: header.path, context: $context)
    }.syncProviders(path: header.path)
    .navigationTitle(app.app.header?.name ?? header.name)
    .environment(app)
    .task(id: SyncTask(path: header.path, context: context)) {
      app.reset()
      await app.sync(hub: hub, path: header.path, context: context)
    }
  }
  struct SyncTask: Hashable {
    let path: String
    let context: Hub.Context
  }
}


struct FileTaskStatus: View {
  @Environment(Hub.self) private var hub
  @Environment(\.serviceContext) private var context
  let session: UploadManager.UploadSession
  let files: [String]
  let uploaded: Int
  let processed: Int
  let target: String
  @State var toClear = 0
  @Binding var isClearing: Bool
  var isUploading: Bool {
    uploaded < files.count
  }
  var isProcessing: Bool {
    processed < files.count
  }
  var title: LocalizedStringKey {
    if isClearing {
      return toClear > 0 ? "Clearing" : "Cleared"
    } else {
      return isUploading ? "Uploading" : "Uploaded"
    }
  }
  var progress: Double {
    return UploadManager.main.progress(for: hub, paths: files, context: context, defaultValue: 1)
  }
  var body: some View {
    VStack {
      HStack(alignment: .top) {
        VStack {
          LargeProgressView(progress: progress, running: files.count - uploaded, completed: uploaded, icon: isClearing ? "trash" : "arrow.up", title: title)
          if !isProcessing && !(isClearing && toClear == 0) {
            AsyncButton {
              try await clear()
            } label: {
              Label("Clear", systemImage: "trash.fill")
            }.buttonStyle(TabButtonStyle(selected: false))
              .transition(.blurReplace)
          }
        }
        VStack {
          LargeProgressView(progress: Double(processed) / Double(files.count), running: files.count - processed, completed: processed, icon: "photo", title: isProcessing ? "Processing" : "Processed")
          if !isProcessing {
            NavigationLink {
              StorageView(path: target).environment(hub).environment(\.serviceContext, context).page()
            } label: {
              Label("View", systemImage: "folder.fill")
            }.buttonStyle(TabButtonStyle(selected: true))
              .transition(.blurReplace)
          }
        }
      }.buttonStyle(.plain).fontWeight(.medium)
    }.contentTransition(.numericText())
  }
  func clear() async throws {
    withAnimation {
      isClearing = true
      toClear = session.files.count
    }
    for file in session.files.map(\.target) {
      try await hub.client.send("s3/delete", file, context: context)
      withAnimation {
        toClear -= 1
      }
    }
  }
}

struct LargeProgressView: View {
  let progress: CGFloat
  let running: Int
  let completed: Int
  let icon: String
  let title: LocalizedStringKey
  @State private var appear = false
  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        Image(systemName: running > 0 ? icon : "checkmark")
          .font(.system(size: 20, weight: .bold))
          .contentTransition(.symbolEffect)
          .gradientBlur(radius: running > 0 ? 1 : 4)
        Circle().trim(from: 0, to: appear ? 1 : 0)
          .rotation(.degrees(-90))
          .stroke(.red.opacity(0.2), lineWidth: 5)
        Circle().trim(from: 0, to: progress)
          .rotation(.degrees(-90))
          .stroke(.red.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .animation(.smooth, value: progress)
      }.frame(width: 48, height: 48)
      if running > 0 {
        Text("\(running)").font(.system(size: 16, weight: .bold, design: .monospaced))
          .contentTransition(.numericText())
          .transition(.blurReplace)
      }
      Text(title).secondary()
    }.frame(width: 100)
      .onAppear { withAnimation(.smooth(duration: 1)) { appear = true } }
      .onDisappear { withAnimation { appear = false } }
  }
}

#Preview {
  ServiceView(header: Hub.AppHeader(name: "Video Encoder", path: "video/encode/ui")).test()
}
