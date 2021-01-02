//
//  KitchenSinkApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI

struct CheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    return HStack {
      configuration.label
      Spacer()
      Image(systemName: configuration.isOn ? "checkmark.square" : "square")
        .resizable()
        .frame(width: 22, height: 22)
        .onTapGesture { configuration.isOn.toggle() }
    }
  }
}

extension Color {
  var isDarkColor: Bool {
    var r, g, b, a: CGFloat
    (r, g, b, a) = (0, 0, 0, 0)
    NSColor(self).usingColorSpace(.extendedSRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return  lum < 0.50
  }
}

@main
struct KitchenSinkApp: App {
  @Environment(\.openURL) var openURL
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    
    WindowGroup("Debug") {
      TaskDebugWindow()
        .padding()
        .frame(minWidth: 600, idealWidth: 600, minHeight: 400, idealHeight: 400)
    }
    
    #if os(macOS)
    Settings {
      SettingsView()
    }
    #endif
  }
}
