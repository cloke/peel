//
//  KitchenSinkApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI

/// This was used in catalyst to make toggles look like checkboxes on MacOS
//struct CheckboxToggleStyle: ToggleStyle {
//  func makeBody(configuration: Configuration) -> some View {
//    return HStack {
//      configuration.label
//      Spacer()
//      Image(systemName: configuration.isOn ? "checkmark.square" : "square")
//        .resizable()
//        .frame(width: 22, height: 22)
//        .onTapGesture { configuration.isOn.toggle() }
//    }
//  }
//}

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
