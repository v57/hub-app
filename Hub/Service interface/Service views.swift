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
  func sync(hub: Hub, path: String) async {
    do {
      print("syncing", path)
      for try await event: AppInterface in hub.client.values(path) {
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
}



extension Element: @retroactive View {
  struct AppState: DynamicProperty {
    @Environment(ServiceApp.self) var app
    @Environment(NestedList.self) var nested: NestedList?
    func translate(_ value: String) -> String? {
      value.staticText ?? self.value(String(value.dropFirst()))
    }
    func value(_ value: String) -> String? {
      nested?.data?[value]?.string ?? app.data[value]?.string
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
            .rotation(.degrees(-90))
            .stroke(.blue.opacity(0.2), lineWidth: 2)
          Circle().trim(from: 0, to: progress)
            .rotation(.degrees(-90))
            .stroke(.blue.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .animation(.smooth, value: progress)
        }.frame(width: 24, height: 24)
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
    @Environment(Hub.self) var hub
    let state = AppState()
    var body: some View {
      let data = state.value(value.value)
      SwiftUI.TextField(value.placeholder, text: $text)
        .task(id: data) {
          if let data, data != text {
            disableUpdates = true
            text = data
          }
        }.task(id: text) {
          if !disableUpdates {
            state.app.store(.string(text), for: value.value, nested: state.nested)
            try? await value.action?.perform(hub: hub, app: state.app, nested: state.nested)
          } else {
            disableUpdates = false
          }
        }
    }
  }
  struct PickerView: View {
    let value: Picker
    @State var selected: String = ""
    @Environment(ServiceApp.self) var app
    @Environment(NestedList.self) var nested: NestedList?
    var body: some View {
      let selected = nested?.data?[value.selected]?.string ?? app.data[value.selected]?.string
      SwiftUI.Picker("", selection: $selected) {
        ForEach(value.options, id: \.self) { value in
          SwiftUI.Text(value).tag(value)
        }
      }.task(id: selected) {
          if let selected {
            self.selected = selected
          } else if let selected = value.options.first {
            self.selected = selected
          }
        }
        .onChange(of: self.selected) {
          app.store(.string(self.selected), for: value.selected, nested: nested)
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
        SwiftUI.Slider(value: v, in: range, step: step)
      } else {
        SwiftUI.Slider(value: v, in: range)
      }
    }
  }
  struct ButtonView: View {
    let value: Button
    @Environment(Hub.self) var hub
    let state = AppState()
    var body: some View {
      if let title = state.translate(value.title) {
        AsyncButton(title) {
          try await value.action.perform(hub: hub, app: state.app, nested: state.nested)
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
    @Environment(Hub.self) private var hub
    @Environment(ServiceApp.self) private var app
    @Environment(NestedList.self) private var nested: NestedList?
    @State private var files = [String]()
    @State private var session: UploadManager.UploadSession?
    var path: String { app.app.header?.name ?? "Services" }
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
          session = UploadManager.main.upload(files: files, directory: path, to: hub)
          return true
        }.onChange(of: session?.tasks == 0) {
          guard let session, session.tasks == 0 else { return }
          let files = session.files.map(\.target)
          Task {
            var links = [AnyCodable]()
            for path in files {
              let url: URL = try await hub.client.send("s3/read", path)
              links.append(.string(url.absoluteString))
            }
            app.store(.array(links), for: value.value, nested: nested)
            try await value.action.perform(hub: hub, app: app, nested: nested)
          }
        }
    }
  }
  struct FileOperationView: View {
    let value: FileOperation
    @Environment(Hub.self) private var hub
    @Environment(ServiceApp.self) private var app
    @Environment(NestedList.self) private var nested: NestedList?
    @State private var files = [String]()
    @State private var session: UploadManager.UploadSession?
    @State private var processed = 0
    @State private var isClearing = false
    @State private var failed = Set<String>()
    var path: String { (app.app.header?.name ?? "Services") + "/" }
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
            session = UploadManager.main.upload(files: files, directory: path, to: hub)
          }
          return true
        }.onChange(of: session?.tasks == 0) {
          guard let session, session.tasks == 0 else { return }
          let files = session.files.map(\.target)
          Task {
            for path in files {
              do {
                let from: String = try await hub.client.send("s3/read", path)
                let target = target(from: path, value: value.value)
                let to: String = try await hub.client.send("s3/write", target)
                try await value.action.perform(hub: hub, app: app, nested: nested) { data in
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
    func target(from path: String, value: String) -> String {
      let result = path.parentDirectory + "Output/" + path.components(separatedBy: "/").last!
      let valueComponents = value.components(separatedBy: ".")
      if valueComponents.count > 1 {
        let ext = valueComponents.last!
        var res = result.components(separatedBy: ".")
        res[res.count - 1] = ext
        return res.joined(separator: ".")
      } else {
        return result
      }
    }
  }
}
extension String {
  var staticText: String? {
    starts(with: "$") ? nil : self
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
  @Environment(Hub.self) var hub
  @State private var app = ServiceApp()
  let header: AppHeader
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
    }.safeAreaPadding()
    .navigationTitle(app.app.header?.name ?? header.name)
    .environment(app)
    .task(id: header.path) { await app.sync(hub: hub, path: header.path) }
  }
}


struct FileTaskStatus: View {
  @Environment(Hub.self) private var hub
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
    return UploadManager.main.progress(for: hub, paths: files, defaultValue: 1)
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
              HStack(spacing: 4) {
                Image(systemName: "trash.fill")
                Text("Clear")
              }.padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.tertiaryBackground, in: .capsule)
                .foregroundStyle(.secondary)
            }.transition(.blurReplace)
          }
        }
        VStack {
          LargeProgressView(progress: Double(processed) / Double(files.count), running: files.count - processed, completed: processed, icon: "photo", title: isProcessing ? "Processing" : "Processed")
          if !isProcessing {
            NavigationLink {
              StorageView(path: target).environment(hub)
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                Text("View")
              }.padding(.horizontal, 12).padding(.vertical, 4)
                .background(.blue, in: .capsule)
            }.transition(.blurReplace)
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
      try await hub.client.send("s3/delete", file)
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
          .stroke(.blue.opacity(0.2), lineWidth: 5)
        Circle().trim(from: 0, to: progress)
          .rotation(.degrees(-90))
          .stroke(.blue.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
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
  NavigationStack {
    ServiceView(header: AppHeader(name: "Image Encoder", path: "image/encode/ui")).environment(Hub.test)
  }
}

