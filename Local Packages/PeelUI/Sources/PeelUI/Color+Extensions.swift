//
//  Color+Extensions.swift
//  PeelUI
//
//  Consolidated from Shared/Extensions/Color.swift and Github/Extensions/Color+Extensions.swift
//  Created on 1/29/26
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
  /// Initialize a Color from a hex string
  /// Supports formats: "FF0000", "#FF0000", "FF0000AA" (with alpha)
  public init(hex string: String) {
    var string: String = string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if string.hasPrefix("#") {
      _ = string.removeFirst()
    }
    
    // Double the last value if incomplete hex
    if !string.count.isMultiple(of: 2), let last = string.last {
      string.append(last)
    }
    
    // Fix invalid values
    if string.count > 8 {
      string = String(string.prefix(8))
    }
    
    // Scanner creation
    let scanner = Scanner(string: string)
    
    var color: UInt64 = 0
    scanner.scanHexInt64(&color)
    
    if string.count == 2 {
      let mask = 0xFF
      let g = Int(color) & mask
      let gray = Double(g) / 255.0
      self.init(.sRGB, red: gray, green: gray, blue: gray, opacity: 1)
      
    } else if string.count == 4 {
      let mask = 0x00FF
      let g = Int(color >> 8) & mask
      let a = Int(color) & mask
      let gray = Double(g) / 255.0
      let alpha = Double(a) / 255.0
      self.init(.sRGB, red: gray, green: gray, blue: gray, opacity: alpha)
      
    } else if string.count == 6 {
      let mask = 0x0000FF
      let r = Int(color >> 16) & mask
      let g = Int(color >> 8) & mask
      let b = Int(color) & mask
      let red = Double(r) / 255.0
      let green = Double(g) / 255.0
      let blue = Double(b) / 255.0
      self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
      
    } else if string.count == 8 {
      let mask = 0x000000FF
      let r = Int(color >> 24) & mask
      let g = Int(color >> 16) & mask
      let b = Int(color >> 8) & mask
      let a = Int(color) & mask
      let red = Double(r) / 255.0
      let green = Double(g) / 255.0
      let blue = Double(b) / 255.0
      let alpha = Double(a) / 255.0
      self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
      
    } else {
      self.init(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
    }
  }
  
  /// Returns true if this color is considered dark (luminance < 0.50)
  public var isDarkColor: Bool {
    var r, g, b, a: CGFloat
    (r, g, b, a) = (0, 0, 0, 0)
    
    #if canImport(UIKit)
    typealias NativeColor = UIColor
    #elseif canImport(AppKit)
    typealias NativeColor = NSColor
    #endif
    
    // On macOS, use NSColor with color space conversion
    NativeColor(self).usingColorSpace(.extendedSRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
    
    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return lum < 0.50
  }
  
  /// Green color as found on github.com
  public static var gitGreen: Color {
    Color(.sRGB, red: 0.157, green: 0.655, blue: 0.271, opacity: 1.0)
  }
}
