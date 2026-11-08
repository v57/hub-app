//
//  APIDescriptionSection.swift
//  Hub
//
//  What a path's services say about it (`hub/api/list`, protocol.md section 15): a title, a description, and the
//  input and output schemas, per kind. Shown in the API inspector; hubs from before descriptions show nothing.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

struct APIDescriptionSection: View {
  let path: String
  @Environment(Hub.self) private var hub
  @State private var entries: [ApiDescription] = []

  /// Entries that say something beyond their path and kind
  private var described: [ApiDescription] {
    entries.filter { $0.title != nil || $0.description != nil || $0.inputSchema != nil || $0.outputSchema != nil }
  }

  var body: some View {
    Group {
      if !described.isEmpty {
        KitSection("About", meta: described.compactMap { $0.kind?.title }, systemImage: "text.book.closed", hue: .teal) {
          ForEach(described) { entry in
            APIDescriptionEntry(entry: entry, showsKind: entries.count > 1)
          }
        }
      }
    }
    .task(id: path) {
      entries = []
      guard !hub.isDemo else { return }
      do {
        for try await list: [ApiDescription] in hub.client.values("hub/api/list") {
          let mine = list.filter { $0.path == path }
          if mine != entries { entries = mine }
        }
      } catch {
        // A hub from before descriptions answers `api not found`
      }
    }
  }
}

private struct APIDescriptionEntry: View {
  let entry: ApiDescription
  let showsKind: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if entry.title != nil || showsKind {
        HStack(spacing: 6) {
          if let title = entry.title { Text(title).kitFont(.headline) }
          if showsKind, let kind = entry.kind { Chip(kind.title, hue: kind == .stream ? .purple : .blue).controlSize(.mini) }
          if entry.annotations?.readOnlyHint == true { Chip(String(localized: "Read-only"), hue: .green).controlSize(.mini) }
          if entry.annotations?.destructiveHint == true { Chip(String(localized: "Destructive"), hue: .red).controlSize(.mini) }
        }
      }
      if let description = entry.description {
        Text(description).kitFont(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if let input = entry.inputSchema {
        SchemaBlock(label: String(localized: "Input"), schema: input)
      }
      if let output = entry.outputSchema {
        SchemaBlock(label: entry.kind == .stream ? String(localized: "Each value") : String(localized: "Output"), schema: output)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A schema as a short type, then its properties with their descriptions
private struct SchemaBlock: View {
  let label: String
  let schema: JSONSchema

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(label).kitFont(.caption)
        Text(schema.typeText(depth: 0)).kitFont(.monoSmall).lineLimit(3).textSelection(.enabled)
      }
      if let description = schema.description {
        Text(description).kitFont(.caption)
      }
      ForEach(schema.properties, id: \.name) { property in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(schema.required.contains(property.name) ? property.name : "\(property.name)?").kitFont(.monoSmall)
          Text(property.schema.typeText(depth: 1)).kitFont(.monoSmall).foregroundStyle(.kitSecondary).lineLimit(1)
          if let description = property.schema.description {
            Text(description).kitFont(.caption).lineLimit(2)
          }
        }
        .padding(.leading, 10)
      }
    }
  }
}

extension ApiDescription.Kind {
  var title: String {
    switch self {
    case .post: String(localized: "Call")
    case .stream: String(localized: "Stream")
    }
  }
}

extension JSONSchema {
  /// A TypeScript-like type: `{ path: string, limit?: integer }`, `string[]`, `"a" | "b"`
  func typeText(depth: Int) -> String {
    if let cases, !cases.isEmpty { return cases.map(\.text).joined(separator: " | ") }
    if let const { return const.text }
    if let anyOf, !anyOf.isEmpty { return anyOf.map { $0.typeText(depth: depth + 1) }.joined(separator: " | ") }
    let kinds = type.map { kind -> String in
      switch kind {
      case .array: return "\(items.map { $0.typeText(depth: depth + 1) }.map { $0.contains(" ") ? "(\($0))" : $0 } ?? "any")[]"
      case .object:
        guard !properties.isEmpty else { return "object" }
        guard depth < 2 else { return "{…}" }
        let fields = properties.map { "\(required.contains($0.name) ? $0.name : "\($0.name)?"): \($0.schema.typeText(depth: depth + 1))" }
        return "{ \(fields.joined(separator: ", ")) }"
      case .string: return format.map { "string (\($0))" } ?? "string"
      default: return kind.rawValue
      }
    }
    return kinds.isEmpty ? "any" : kinds.joined(separator: " | ")
  }
}

extension JSONSchema.Value {
  var text: String {
    switch self {
    case .null: "null"
    case .bool(let value): "\(value)"
    case .int(let value): "\(value)"
    case .double(let value): "\(value)"
    case .string(let value): "\"\(value)\""
    case .array: "[…]"
    case .object: "{…}"
    }
  }
}
#endif
