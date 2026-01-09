//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Git

enum CurrentTool: String, Identifiable, CaseIterable {
  case agents = "agents", brew = "brew", git = "git", github = "github"
  var id: String { rawValue }
}

/// Entry point for MacOS
struct ContentView: View {
  @AppStorage(wrappedValue: .brew, "current-tool") private var currentTool: CurrentTool
  
  var body: some View {
    switch currentTool {
    case .agents: Agents_RootView()
    case .brew: Brew_RootView()
    case .git: Git_RootView()
    case .github: Github_RootView()
    }
  }
}

#Preview {
  ContentView()
}
