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
        .onOpenURL { url in
          print("=== URL CALLBACK RECEIVED ===")
          print("URL: \(url.absoluteString)")
          print("Scheme: \(url.scheme ?? "nil")")
          print("Host: \(url.host ?? "nil")")
          print("Path: \(url.path)")
          print("Query: \(url.query ?? "nil")")
          print("Fragment: \(url.fragment ?? "nil")")
          print("URL Components:")
          if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            print("  - Query Items: \(components.queryItems?.description ?? "nil")")
          }
          print("OS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
          print("=============================")
          
          // Handle the OAuth callback
          let handled = OAuthSwift.handle(url: url)
          print("OAuth handled: \(handled)")
        }
    }
    .handlesExternalEvents(matching: ["*"])
    #if os(macOS)
    // Additional handler at the app level for macOS
    .commands {
      CommandGroup(replacing: .newItem) {
        // This ensures the app can handle URL events
      }
    }
    #endif
    
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
