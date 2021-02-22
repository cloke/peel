//
//  Color.swift
//  KitchenSink (macOS)
//
//  Created by Cory Loken on 2/22/21.
//

import SwiftUI

extension Color {
  var isDarkColor: Bool {
    var r, g, b, a: CGFloat
    (r, g, b, a) = (0, 0, 0, 0)
    NSColor(self).usingColorSpace(.extendedSRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return  lum < 0.50
  }
}
