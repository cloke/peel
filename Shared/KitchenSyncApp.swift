//
//  KitchenSyncApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import Foundation
import SwiftUI
import OAuthSwift

@main
struct KitchenSyncApp: App {
  @Environment(\.openURL) var openURL
  
  var body: some Scene {
    WindowGroup {
      ContentView()
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
          OAuthSwift.handle(url: url)
        }
    }
    
#if os(macOS)
    WindowGroup("Debug") {
      TaskDebugWindow()
        .padding()
        .frame(minWidth: 600, idealWidth: 600, minHeight: 400, idealHeight: 400)
    }
    
    Settings {
      SettingsView()
    }
#endif
  }
}
