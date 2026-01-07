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
    // TaskDebugWindow removed - no longer needed after TaskRunner removal
    
    Settings {
      SettingsView()
    }
#endif
  }
}
