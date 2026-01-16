//
//  ContentView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 6/10/22.
//  Updated for TabView navigation on 1/16/26
//

import SwiftUI

/// Available tools for iOS
/// Note: Workspaces and Agents are macOS-only due to terminal/VM requirements
enum iOSTool: String, CaseIterable, Identifiable {
  case github = "GitHub"
  case git = "Git"
  case brew = "Brew"
  case agents = "Agents"
  
  var id: String { rawValue }
  
  var icon: String {
    switch self {
    case .github: "person.2.fill"
    case .git: "arrow.triangle.branch"
    case .brew: "mug.fill"
    case .agents: "cpu.fill"
    }
  }
}

/// Entry point for iOS
struct ContentView: View {
  @State private var selectedTool: iOSTool = .github
  
  var body: some View {
    TabView(selection: $selectedTool) {
      Tab(iOSTool.github.rawValue, systemImage: iOSTool.github.icon, value: .github) {
        Github_RootView()
      }
      
      Tab(iOSTool.git.rawValue, systemImage: iOSTool.git.icon, value: .git) {
        GitUnavailableView()
      }
      
      Tab(iOSTool.brew.rawValue, systemImage: iOSTool.brew.icon, value: .brew) {
        BrewUnavailableView()
      }
      
      Tab(iOSTool.agents.rawValue, systemImage: iOSTool.agents.icon, value: .agents) {
        AgentsUnavailableView()
      }
    }
  }
}

/// Placeholder for Git tab on iOS
struct GitUnavailableView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Git Repositories", systemImage: "arrow.triangle.branch")
      } description: {
        Text("Local git repository management requires filesystem access and is only available on macOS.")
      } actions: {
        Text("Use the GitHub tab to browse your remote repositories.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("Git")
    }
  }
}

/// Placeholder for Brew tab on iOS
struct BrewUnavailableView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Homebrew", systemImage: "mug.fill")
      } description: {
        Text("Homebrew package management is only available on macOS.")
      } actions: {
        Text("Open Kitchen Sync on your Mac to manage packages.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("Homebrew")
    }
  }
}

/// Placeholder for Agents tab on iOS
struct AgentsUnavailableView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Agents", systemImage: "cpu.fill")
      } description: {
        Text("Agent orchestration requires terminal access and is only available on macOS.")
      } actions: {
        Text("Open Kitchen Sync on your Mac to use AI agents.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("Agents")
    }
  }
}

#Preview {
  ContentView()
}
