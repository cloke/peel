//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
#if os(macOS)
import Git
#endif

struct Command {
  static let BrewInstalled = ["list", "--formula"]
  static let BrewAvailable = ["search", "--formula"]
  static let BrewInfo = ["info", "--json"]
  static let BrewInstall = ["install"]
  
  static let GitBranch = "branch"
}


#if os(iOS)
struct ContentView: View {
  var body: some View {
    NavigationView {
      Github_RootView()
    }
  }
}
#else
enum CurrentTool: String, Identifiable, CaseIterable {
  case brew = "brew", git = "git", github = "github"
  var id: String { rawValue }
}

struct ContentView: View {
  @AppStorage(wrappedValue: .brew, "current-tool") private var currentTool: CurrentTool
  
  var body: some View {
    NavigationView {
      VStack {
        switch currentTool {
        case .brew: Brew_RootView()
        case .git: Git_RootView()
        case .github: Github_RootView()
        }
      }
    }
  }
}
#endif
struct ContentView_Previews: PreviewProvider {
  static var previews: some View {
    ContentView()
  }
}
