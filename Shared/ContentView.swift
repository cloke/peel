//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI

enum CurrentTool: String, Identifiable, CaseIterable {
  case brew = "brew", git = "git"
  
  var id: String { rawValue }
}

enum Executable: String {
  case brew = "/usr/local/bin/brew"
  case archetecture = "/usr/bin/arch"
  case git = "/usr/bin/git"
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

  func toggleSidebar() { NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)}

  var body: some View {
    NavigationView {
    VStack {
      switch currentTool {
      case .brew:
        Brew.RootView()
      case .git:
        Git.RootView()
      }
    }
    }
    .toolbar {
      ToolbarItem(placement: .navigation){
        Button { toggleSidebar() }
          label: { Image(systemName: "sidebar.left") }
      }
      
      ToolbarItem(placement: .primaryAction) {
        Menu(currentTool.rawValue.capitalized) {
          Button(CurrentTool.brew.rawValue.capitalized) { currentTool = .brew }
          Button(CurrentTool.git.rawValue.capitalized) { currentTool = .git }
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
