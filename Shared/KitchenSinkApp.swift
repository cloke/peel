//
//  KitchenSinkApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import OAuthSwift

//let config = OAuthConfiguration(token: "5839b088c4fed070f6e4", secret: "e8cf6fbbb3f25d8671938e3fc375f631c97aa4d4", scopes: ["repo", "read:org"])
//let url = config.authenticate()

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ aNotification: Notification) {
    NSAppleEventManager.shared().setEventHandler(self, andSelector:#selector(AppDelegate.handleGetURL(event:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  }
  
  @objc func handleGetURL(event: NSAppleEventDescriptor!, withReplyEvent: NSAppleEventDescriptor!) {
    if let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: urlString) {
      OAuthSwift.handle(url: url)
    }
  }
}

@main
struct KitchenSinkApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  
  //  @Environment(\.openURL) var openURL
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
