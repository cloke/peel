//
//  KitchenSinkApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI

struct SettingsView: View {
  @ObservedObject private var gitViewModel: Git.ViewModel = .shared

  var body: some View {
    
    Form {
      Button("Reset Git") {
        gitViewModel.resetSettings()
      }
      .help("Removes all references to repositories. Does not affect actual repository.")

    }
    .padding()
    .frame(minWidth: 400, minHeight: 400)
  }
}

@main
struct KitchenSinkApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    #if os(macOS)
    Settings {
      SettingsView()
    }
    #endif
  }
}
