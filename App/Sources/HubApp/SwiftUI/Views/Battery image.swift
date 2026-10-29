//
//  Battery image.swift
//  Hub
//
//  A battery symbol for a charge level.
//

import SwiftUI

extension Image {
  init(battery: Float, charging: Bool) {
    if charging {
      self.init(systemName: "battery.100percent.bolt")
    } else {
      switch battery {
      case ...0.1:
        self.init(systemName: "battery.0percent")
      case ...0.3:
        self.init(systemName: "battery.25percent")
      case ...0.6:
        self.init(systemName: "battery.50percent")
      case ...0.85:
        self.init(systemName: "battery.75percent")
      default:
        self.init(systemName: "battery.100percent")
      }
    }
  }
}
