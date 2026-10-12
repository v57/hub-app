//
//  Device Usage.swift
//  Hub
//
//  Created by Dmitry on 28.07.26.
//

import SwiftUI

struct DeviceUsage: Identifiable {
  static let examples: [DeviceUsage] = [
    DeviceUsage(
      cpu: CPU(used: [0, 0, 0, 0, 0, 0]),
      ram: RAM(used: 2843523620, total: 16_000_000_000),
      disk: [DISK(used: 384_000_000_000, total: 512_000_000_000)],
      gpu: []),
    DeviceUsage(
      cpu: CPU(ecores: 4, used: [0.99, 0.99, 0.99, 0.99, 0, 0, 0.12, 0.4]),
      ram: RAM(used: 2843523620, total: 16_000_000_000),
      disk: [DISK(used: 63_000_000_000, total: 512_000_000_000)],
      gpu: []),
    DeviceUsage(
      cpu: CPU(ecores: 4, used: [0.99, 0.99, 0, 0, 0.42, 0.32, 0.12, 0.4]),
      ram: RAM(used: 2843523620, total: 16_000_000_000),
      disk: [DISK(used: 280_000_000_000, total: 512_000_000_000)],
      gpu: [GPU(id: 0, usage: 0.16)]),
    DeviceUsage(
      cpu: CPU(ecores: 4, used: [0.99, 0.99, 0.0, 0.0, 0.42, 0.32, 0.12, 0.4]),
      ram: RAM(used: 2843523620, total: 16_000_000_000),
      disk: [DISK(used: 280_000_000_000, total: 512_000_000_000)],
      gpu: [
        GPU(id: 0, usage: 0.16),
        GPU(id: 1, usage: 0.53, ram: RAM(used: 14_000_000_000, total: 24_000_000_000)),
      ]),
  ]
  let id = UUID()
  var cpu: CPU
  var ram: RAM
  var disk: [DISK]
  var gpu: [GPU]
  init(cpu: CPU, ram: RAM, disk: [DISK], gpu: [GPU]) {
    self.cpu = cpu
    self.ram = ram
    self.disk = disk
    self.gpu = gpu
  }
  struct CPU {
    var ecores: Int = 0
    var used: [Float]
    var usage: Float {
      used.reduce(into: 0, +=) / Float(used.count)
    }
  }
  struct RAM {
    var used: Int
    var total: Int
    var usage: Float {
      Float(used) / Float(total)
    }
  }
  struct DISK: Identifiable {
    var id: Int = 0
    var used: Int
    var total: Int
    var usage: Float {
      Float(used) / Float(total)
    }
  }
  struct GPU: Identifiable {
    let id: Int
    var usage: Float
    var ram: RAM?
  }
  
  struct CompactView: View {
    let usage: DeviceUsage
    var body: some View {
      HStack {
        CircleProgress(value: usage.cpu.usage) {
          Image(systemName: "cpu")
        }
        CircleProgress(value: usage.ram.usage) {
          Image(systemName: "memorychip")
        }
        ForEach(usage.gpu) { gpu in
          CircleProgress(value: gpu.usage) {
            Text("GPU").font(.system(size: 8))
          }
        }
        ForEach(usage.disk) { disk in
          CircleProgress(value: disk.usage) {
            Image(systemName: "internaldrive")
          }
        }
      }
    }
  }
  
  struct CompactView1: View {
    let usage: DeviceUsage
    var body: some View {
      HStack {
        CircleProgress(value: usage.cpu.usage) {
          Text("C")
        }
        CircleProgress(value: usage.ram.usage) {
          Text("M")
        }
        ForEach(usage.gpu) { gpu in
          CircleProgress(value: gpu.usage) {
            Text("G")
          }
        }
        ForEach(usage.disk) { disk in
          CircleProgress(value: disk.usage) {
            Text("S")
          }
        }
      }
    }
  }
  
  struct CompactView2: View {
    let usage: DeviceUsage
    var body: some View {
      HStack {
        CircleProgress(value: usage.cpu.usage) {
          Text("CPU").font(.system(size: 8))
        }
        CircleProgress(value: usage.ram.usage) {
          Text("MEM").font(.system(size: 8))
        }
        ForEach(usage.gpu) { gpu in
          CircleProgress(value: gpu.usage) {
            Text("GPU").font(.system(size: 8))
          }
        }
        ForEach(usage.disk) { disk in
          CircleProgress(value: disk.usage) {
            Text("SSD").font(.system(size: 8))
          }
        }
      }
    }
  }
  struct CompactView3: View {
    let usage: DeviceUsage
    var body: some View {
      HStack {
        VStack(alignment: .trailing) {
          Text("CPU").foregroundStyle(.secondary)
          Text("\(Int(usage.cpu.usage * 100))%")
        }
        VStack(alignment: .trailing) {
          Text("MEM").foregroundStyle(.secondary)
          Text("\(Int(usage.ram.usage * 100))%")
        }
        ForEach(usage.gpu) { gpu in
          VStack(alignment: .trailing) {
            Text("GPU").foregroundStyle(.secondary)
            Text("\(Int(gpu.usage * 100))%")
          }
        }
        ForEach(usage.disk) { disk in
          VStack(alignment: .trailing) {
            Text("SSD").foregroundStyle(.secondary)
            Text("\(Int(disk.usage * 100))%")
          }
        }
      }.font(.system(size: 8)).monospacedDigit()
    }
  }
  struct CompactView4: View {
    let usage: DeviceUsage
    var body: some View {
      HStack {
        CircleProgress(value: usage.cpu.usage) {
          Text("CPU").font(.system(size: 8))
        }
        CircleProgress(value: usage.ram.usage) {
          Text("MEM").font(.system(size: 8))
        }
        ForEach(usage.gpu) { gpu in
          CircleProgress(value: gpu.usage) {
            Text("GPU").font(.system(size: 8))
          }
        }
        ForEach(usage.disk) { disk in
          CircleProgress(value: disk.usage) {
            Text("SSD").font(.system(size: 8))
          }
        }
      }
    }
  }
  struct CircleProgress<Icon: View>: View {
    let value: Float
    @ViewBuilder let icon: Icon
    var body: some View {
      ZStack {
        icon.foregroundStyle(.blue)
        Circle().stroke(.tint.opacity(0.2), lineWidth: 1)
        Circle().trim(from: 0, to: Double(value))
          .rotation(.degrees(-90))
          .stroke(.blue.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
      }.frame(width: 32, height: 32)
    }
  }
}

#Preview {
  ScrollView {
    VStack {
      HStack {
        VStack(alignment: .leading) {
          ForEach(DeviceUsage.examples) { usage in
            DeviceUsage.CompactView(usage: usage)
          }
        }.frame(maxWidth: .infinity)
        VStack(alignment: .leading) {
          ForEach(DeviceUsage.examples) { usage in
            DeviceUsage.CompactView2(usage: usage)
          }
        }.frame(maxWidth: .infinity)
        VStack(alignment: .leading) {
          ForEach(DeviceUsage.examples) { usage in
            DeviceUsage.CompactView1(usage: usage)
          }
        }.frame(maxWidth: .infinity)
      }
      VStack(alignment: .leading) {
        ForEach(DeviceUsage.examples) { usage in
          DeviceUsage.CompactView3(usage: usage)
        }
      }.frame(maxWidth: .infinity)
      HStack {
        DeviceUsage.CompactView4(usage: DeviceUsage.examples.last!)
      }
    }.padding()
  }//.frame(maxWidth: .infinity, maxHeight: .infinity)
}
