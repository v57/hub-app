//
//  ContentView.swift
//  Hub
//
//  Created by Dmitry Kozlov on 16/2/25.
//

import SwiftUI

struct Toolbar: View {
  var body: some View {
    NavigationStack {
      if #available(macOS 15.0, iOS 18.0, *) {
        TabView {
          Tab("Home", systemImage: "house.fill") {
            HomeView()
          }
          Tab("Farm", systemImage: "tree.fill") {
            FarmView()
          }
        }
      } else {
        TabView {
          HomeView().tabItem {
            Label("Home", systemImage: "house.fill")
          }
          FarmView().tabItem {
            Label("Farm", systemImage: "tree.fill")
          }
        }
      }
    }
  }
}

