//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Git

enum CurrentTool: String, Identifiable, CaseIterable {
  case brew = "brew", git = "git"
  
  var id: String { rawValue }
}

struct Command {
  static let BrewInstalled = ["list", "--formula"]
  static let BrewAvailable = ["search", "--formula"]
  static let BrewInfo = ["info", "--json"]
  static let BrewInstall = ["install"]
  
  static let GitBranch = "branch"
}

struct ContentView: View {
  @AppStorage(wrappedValue: .brew, "current-tool") private var currentTool: CurrentTool
  
  var body: some View {
    NavigationView {
      VStack {
        switch currentTool {
        case .brew: Brew_RootView()
        case .git: Git_RootView()
        }
      }
    }
  }
}

struct ContentView_Previews: PreviewProvider {
  static var previews: some View {
    ContentView()
  }
}
