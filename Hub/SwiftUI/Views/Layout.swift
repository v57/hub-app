//
//  Layout.swift
//  Hub
//
//  Created by Linux on 07.02.26.
//

import SwiftUI

extension LazyVGrid {
  init(minWidth: Double, @ViewBuilder content: () -> Content) {
    self.init(columns: [.init(.adaptive(minimum: minWidth))], content: content)
  }
}

extension BinaryInteger {
  public subscript<T: BinaryInteger>(index: T) -> Bool {
    get { self & (1 << index) != 0 }
    set {
      if newValue {
        self |= 1 << index
      } else {
        self &= ~(1 << index)
      }
    }
  }
}
