//
//  Device view.swift
//  Hub
//
//  Created by Dmitry on 26.07.26.
//

import SwiftUI

struct DeviceView: View {
  @State var vpn = true
  var body: some View {
    ScrollView {
      Placeholder(image: "macbook", title: "MacBook Pro") {
        DeviceUsage.CompactView(usage: DeviceUsage.examples.last!)
          .padding(.bottom)
      }
      VStack {
      }.buttonStyle(.environment)
      HStack {
        Button { } label: {
          Label("Open Terminal", systemImage: "terminal")
            .padding(.horizontal, 12).padding(.vertical, 8)
            .hoverEffect(in: .capsule)
        }
        Button {
          vpn.toggle()
        } label: {
          Label("Use as VPN", systemImage: "network")
            .symbolEffect(.bounce, value: vpn)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay {
              if vpn {
                CoolEffect()
              }
            }
            .hoverEffect(in: .capsule)
        }
        Button {
          vpn.toggle()
        } label: {
          Text("Manage")
            .padding(.horizontal, 12).padding(.vertical, 8)
            .hoverEffect(in: .capsule)
        }
      }.buttonStyle(.environment)
      HStack {
        Text("Services")
      }
    }
  }
  struct CircleProgress: View {
    let progress: Float
    var body: some View {
      Circle().strokeBorder(.blue)
        .frame(width: 24, height: 24)
    }
  }
  struct CoolEffect: View {
    @State var appear = false
    var body: some View {
      let offset: Double = appear ? 1 : -1
      Capsule().strokeBorder(.blue)
        .strokeBorder(LinearGradient(colors: [.clear, .white, .clear], startPoint: UnitPoint(x: offset, y: offset), endPoint: UnitPoint(x: offset + 1, y: offset + 1)))
        .animation(.smooth.delay(1), value: appear)
        .mask {
          Color.black.frame(maxWidth: appear ? .infinity : 0, alignment: .leading)
            .animation(.smooth, value: appear)
        }
        .onAppear {
          appear = true
        }.onDisappear { appear = false }
    }
  }
}

#Preview {
  DeviceView().test().frame(maxWidth: .infinity)
}
