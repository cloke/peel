//
//  KitchenSinkApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI

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
