//
//  FilesPage.swift
//  Hub
//
//  The hub's storage: its places as cards on top (every S3 service), the open folder as a table under a path bar,
//  and the selected file in the inspector. Files dropped on the table upload into the open folder.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

struct FilesPage: View {
  @Environment(Hub.self) private var hub
  @State private var places: [Place] = []
  @State private var place: String?
  @State private var path = ""
  @State private var list = Listing()
  @State private var isLoading = true
  @State private var selection: String?
  @State private var sort: KitGridSort? = KitGridSort("Name")
  @State private var search = ""
  @State private var importing = false
  @Environment(\.kitIdiom) private var idiom

  struct Place: Identifiable, Hashable {
    let id: String
    let name: String
  }

  var body: some View {
    Group {
      if !hub.hasStorage {
        InstallS3().kitPane(.content)
      } else {
        PageWithInspector(name: "files", showsInspector: selected != nil) {
          VStack(alignment: .leading, spacing: KitMetrics.gutter) {
            if places.count > 1 {
              ScrollView(.horizontal) {
                HStack(spacing: KitMetrics.gutter) {
                  ForEach(places) { item in
                    GridCard(isSelected: place == item.id, action: { open(item.id) }) {
                      RichHeader(item.name, meta: ["S3"], systemImage: "externaldrive", hue: .orange)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                    }
                    .frame(width: 200)
                  }
                }
              }
              .scrollIndicators(.never)
            }
            HStack(spacing: 6) {
              Button("Back", systemImage: "chevron.left") { goUp() }
                .buttonStyle(.kitIcon).disabled(path.isEmpty)
              ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.kitTertiary) }
                Button(crumb.name) { path = crumb.path }
                  .buttonStyle(.plain)
                  .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
              }
              Spacer()
              Text(MetaLine.join([rows.count == 1 ? "1 item" : "\(rows.count) items", totalSize])).kitFont(.caption)
            }
            .padding(.horizontal, 4)
            if isLoading && rows.isEmpty {
              LoadingCards()
              Spacer()
            } else if rows.isEmpty {
              EmptyState(systemImage: "folder", title: search.isEmpty ? "Empty Folder" : "No Files Match", message: search.isEmpty ? "Drop files here to upload them." : nil)
                .frame(maxHeight: .infinity)
            } else {
              KitGrid(rows, columns: columns, selection: Binding {
                selection.map { [$0] } ?? []
              } set: { ids in
                withAnimation(.kit) { selection = ids.first }
              }, sort: $sort, primaryAction: { ids in
                if let id = ids.first, id.hasSuffix("/") { path += id }
              }) {
                EmptyView()
              }
            }
          }
          .padding(KitMetrics.gutter)
          .dropDestination(for: URL.self) { urls, _ in
            upload(urls)
            return true
          }
        } inspector: {
          if let file = selected {
            FileInspector(file: file, path: path, context: HubContext(service: place)) {
              await delete(file)
            }
          }
        }
      }
    }
    .pageToolbar("Files", meta: PageMeta.parts(hub, [places.count > 1 ? "\(places.count) storage places" : ""]), systemImage: HubPage.files.systemImage, hue: .blue) {
      if idiom != .phone && hub.hasStorage {
        KitSearchField(text: $search, prompt: "Search Files").frame(width: 180)
      }
      if hub.hasStorage && hub.require(permissions: "s3/write") && idiom != .tv {
        ToolGroup {
          Button("Upload", systemImage: "arrow.up.doc") { importing = true }
        }
      }
    }
#if !os(tvOS)
    .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      if case .success(let urls) = result { upload(urls) }
    }
#endif
    .task(id: hub.isConnected) {
      guard hub.hasStorage, !hub.isDemo else { return }
      do {
        for try await providers in hub.client.devices.providers("s3/list") {
          places = providers.map { Place(id: $0.id, name: $0.name ?? "Storage") }
          if place == nil || !places.contains(where: { $0.id == place }) { place = places.first?.id }
        }
      } catch { }
    }
    .task(id: "\(place ?? "")/\(path)") {
      guard place != nil || places.isEmpty, hub.hasStorage, !hub.isDemo else { return }
      isLoading = true
      selection = nil
      do {
        for try await list: Listing in hub.client.values("s3/list", path, context: HubContext(service: place)) {
          self.list = list
          isLoading = false
        }
      } catch {
        list = Listing()
        isLoading = false
      }
    }
  }

  private struct Crumb { let name: String; let path: String }
  private var crumbs: [Crumb] {
    var result = [Crumb(name: places.first { $0.id == place }?.name ?? "Files", path: "")]
    var current = ""
    for part in path.split(separator: "/") {
      current += part + "/"
      result.append(Crumb(name: String(part), path: current))
    }
    return result
  }

  private var rows: [FileRow] {
    let folders = list.directories.map { FileRow(id: $0.hasSuffix("/") ? $0 : $0 + "/", size: nil, modified: nil) }
    let files = list.files.map { FileRow(id: $0.name, size: $0.size, modified: $0.lastModified) }
    let all = (folders + files).filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }
    guard let sort else { return all }
    return all.sorted { a, b in
      if a.isFolder != b.isFolder { return a.isFolder }
      let less: Bool = switch sort.column {
      case "Size": (a.size ?? 0) < (b.size ?? 0)
      case "Kind": a.kind < b.kind
      case "Modified": (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
      default: a.id.localizedStandardCompare(b.id) == .orderedAscending
      }
      return sort.ascending ? less : !less
    }
  }

  private var totalSize: String {
    let total = list.files.reduce(0) { $0 + $1.size }
    return total > 0 ? Int64(total).formatted(.byteCount(style: .file)) : ""
  }

  private var selected: FileRow? {
    selection.flatMap { id in rows.first { $0.id == id && !$0.isFolder } }
  }

  private var columns: [KitGridColumn<FileRow>] {
    [
      KitGridColumn("Name", width: 280) { row in
        HStack(spacing: 8) {
          Tile(systemImage: row.systemImage, hue: row.isFolder ? .blue : .gray, size: 18)
          Text(row.name).lineLimit(1)
        }
      },
      KitGridColumn("Size", width: 90, alignment: .trailing, value: { $0.size.map { Int64($0).formatted(.byteCount(style: .file)) } ?? "–" }),
      KitGridColumn("Kind", width: 110, value: { $0.kind }),
      KitGridColumn("Modified", width: 150, value: { $0.modified?.formatted(date: .abbreviated, time: .shortened) ?? "–" }),
    ]
  }

  private func open(_ id: String) {
    place = id
    path = ""
  }

  private func goUp() {
    var parts = path.split(separator: "/")
    guard !parts.isEmpty else { return }
    parts.removeLast()
    path = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
  }

  private func upload(_ urls: [URL]) {
    HubStorageUpload.upload(files: urls, directory: path, to: hub.client, context: HubContext(service: place))
  }

  private func delete(_ file: FileRow) async {
    do {
      try await hub.client.send("s3/delete", path + file.id, context: HubContext(service: place))
      selection = nil
    } catch { }
  }
}

/// `s3/list`: a folder's files and subfolders
struct Listing: Decodable {
  var files: [File] = []
  var directories: [String] = []
  struct File: Decodable {
    let name: String
    let size: Int
    let lastModified: Date?
  }
}

struct FileRow: Identifiable, Hashable {
  let id: String
  let size: Int?
  let modified: Date?
  var isFolder: Bool { id.hasSuffix("/") }
  var name: String { isFolder ? String(id.dropLast()) : id }
  var ext: String { isFolder ? "" : (id.split(separator: ".").count > 1 ? String(id.split(separator: ".").last!).lowercased() : "") }
  var kind: String {
    if isFolder { return "Folder" }
    switch ext {
    case "heic", "jpg", "jpeg", "png", "gif", "webp": return "\(ext.uppercased()) image"
    case "mov", "mp4", "m4v": return "Movie"
    case "m4a", "mp3", "wav", "aac": return "Audio"
    case "pdf": return "PDF"
    case "": return "File"
    default: return ext.uppercased()
    }
  }
  var systemImage: String {
    if isFolder { return "folder" }
    switch kind {
    case let k where k.hasSuffix("image"): return "photo"
    case "Movie": return "film"
    case "Audio": return "waveform"
    case "PDF": return "doc.richtext"
    default: return "doc"
    }
  }
}

/// The selected file: where it is, its size and date, a temporary link, and deleting it
private struct FileInspector: View {
  let file: FileRow
  let path: String
  let context: HubContext
  let delete: () async -> Void
  @Environment(Hub.self) private var hub
  @State private var copied = false
  @State private var isDeleting = false

  var body: some View {
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      KitSection(file.name, meta: [file.kind, file.size.map { Int64($0).formatted(.byteCount(style: .file)) } ?? ""], systemImage: file.systemImage, hue: .blue) {
        InspectorRow("Folder", value: "/" + path, copyable: true)
        if let modified = file.modified {
          InspectorRow("Modified", value: modified.formatted(date: .abbreviated, time: .shortened), copyable: false)
        }
        if let size = file.size {
          InspectorRow("Size", value: Int64(size).formatted(.byteCount(style: .file)), copyable: false)
        }
      }
      HStack {
        if hub.require(permissions: "s3/read") {
          AsyncButton(copied ? "Copied" : "Copy Link") {
            let link: String = try await hub.client.send("s3/read", path + file.id, context: context)
            link.copyToClipboard()
            copied = true
          }
          .buttonStyle(.kit)
        }
        if hub.require(permissions: "s3/delete") {
          Button("Delete…") { isDeleting = true }.buttonStyle(.kit).foregroundStyle(Hue.red.text)
        }
      }
      .controlSize(.small)
    }
    .onChange(of: file.id) { copied = false }
    .kitDialog("Delete \(file.name)?", isPresented: $isDeleting, message: "It’s removed from the hub’s storage for everyone.", systemImage: "trash", hue: .red, confirm: "Delete", role: .destructive) {
      Task { await delete() }
    }
  }
}
#endif
