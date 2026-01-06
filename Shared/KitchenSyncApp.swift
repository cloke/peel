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
