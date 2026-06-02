//
//  Library picker.swift
//  Hub
//
//  Created by Linux on 02.06.26.
//

import PhotosUI
import SwiftUI

struct LibraryPickerButton: View {
  @State private var photos = [PhotosPickerItem]()
  let matching: PHPickerFilter
  let picked: (URL) -> Void
  var body: some View {
    PhotosPicker(selection: $photos, matching: matching) {
      HStack {
        if photos.isEmpty {
          Image(systemName: "photo.stack").transition(.scale)
        } else {
          Text(photos.count, format: .number).monospacedDigit()
            .transition(.scale)
        }
        Text("Select From Library")
      }
    }.task(id: photos) {
      while !photos.isEmpty {
        let photo = withAnimation { photos.removeFirst() }
        do {
          if let url = try await photo.loadTransferable(type: LibraryTransferable.self)?.url {
            picked(url)
          }
        } catch { print(error) }
      }
    }
  }
}
struct LibraryTransferable: Transferable {
  let url: URL
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .data) { item in
      SentTransferredFile(item.url)
    } importing: { item in
      let files = FileManager.default
      let directory = URL.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, conformingTo: .directory)
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      let target = directory.appendingPathComponent(item.file.lastPathComponent)
      try FileManager.default.copyItem(at: item.file, to: target)
      return LibraryTransferable(url: target)
    }
  }
}
