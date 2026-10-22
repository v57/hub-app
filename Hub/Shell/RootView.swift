//
//  RootView.swift
//  Hub
//
//  The window: the sidebar, and the page its selection opens. On iPhone the sidebar is the root list and pages push.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

/// Sheets and confirmations any page can ask the window for
@MainActor @Observable
final class ShellModel {
  var sheet: Sheet?
  /// The hub whose removal waits for a confirmation
  var removing: Hub?
  enum Sheet: Identifiable, Hashable {
    case connect, joinNetwork
    var id: Self { self }
  }
}

struct RootView: View {
  @State private var navigator = Navigator.main
  @State private var shell = ShellModel()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
      HubSidebar(columnVisibility: $columnVisibility)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 360)
    } detail: {
      Group {
        if idiom == .phone {
          NavigationStack { DetailView() }
        } else {
          DetailView()
        }
      }
      .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
    .environment(shell)
    .sheet(item: $shell.sheet) { sheet in
      Group {
        switch sheet {
        case .connect: ConnectSheet()
        case .joinNetwork: JoinNetworkSheet()
        }
      }
      .environment(shell)
      .componentKit(accent: .hubAccent)
    }
    .kitDialog(
      "Remove \(shell.removing?.settings.name ?? "Hub")?",
      isPresented: Binding { shell.removing != nil } set: { if !$0 { shell.removing = nil } },
      message: "This app forgets the hub and its address. The hub keeps your key until an owner removes it.",
      systemImage: "trash", hue: .red, confirm: "Remove", role: .destructive
    ) {
      guard let hub = shell.removing else { return }
      if Navigator.main.route?.hubID == hub.id { Navigator.main.route = .allHubs }
      Hubs.main.remove(with: hub.settings)
    }
    .onChange(of: navigator.route) { _, _ in compactColumn = .detail }
  }
}

/// The page the sidebar's selection opens
struct DetailView: View {
  @State private var navigator = Navigator.main
  @State private var hubs = Hubs.main

  var body: some View {
    switch navigator.route ?? .allHubs {
    case .allHubs:
      AllHubsView()
    case .hub(let id, let page):
      if let hub = hubs.list.first(where: { $0.id == id }) {
        HubPageView(page: page).hub(hub).id(hub.id)
      } else {
        AllHubsView()
      }
    case .app(let id, let path):
      if let hub = hubs.list.first(where: { $0.id == id }) {
        ServiceAppPage(path: path).hub(hub).id("\(id)/\(path)")
      } else {
        AllHubsView()
      }
    case .hubHome(let id):
      if let hub = hubs.list.first(where: { $0.id == id }) {
        HubPagesList().hub(hub).id(hub.id)
      } else {
        AllHubsView()
      }
    case .device(let page):
      DevicePageView(page: page)
    }
  }
}

extension Color {
  /// Hub's accent: the red of its icon
  static let hubAccent = Color(.sRGB, red: 1, green: 0.22, blue: 0.235)
}
#endif
