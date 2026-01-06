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
        .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*")) // activate existing window if exists
        .onOpenURL { url in
          print("=== URL CALLBACK RECEIVED ===")
          print("URL: \(url.absoluteString)")
          print("Scheme: \(url.scheme ?? "nil")")
          print("Host: \(url.host ?? "nil")")
          print("Path: \(url.path)")
          print("Query: \(url.query ?? "nil")")
          print("=============================")
          OAuthSwift.handle(url: url)
        }
    }
    .handlesExternalEvents(matching: Set(arrayLiteral: "*")) // create new window if doesn't exist
    
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
