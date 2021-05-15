//
//  Color.swift
//  
//
//  Created by Cory Loken on 1/30/21.
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
  
  public static var gitGreen: Color {
    /// Green color as found on github.com
    return Color.init(.sRGB, red: 0.157, green: 0.655, blue: 0.271, opacity: 1.0)
  }
}
