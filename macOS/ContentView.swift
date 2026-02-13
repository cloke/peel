//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Git
import Github

enum CurrentTool: String, Identifiable, CaseIterable {
  case agents = "agents", workspaces = "workspaces", brew = "brew", repositories = "repositories", git = "git", github = "github", swarm = "swarm"
  var id: String { rawValue }
}

/// Entry point for MacOS
struct ContentView: View {
  @AppStorage(wrappedValue: .repositories, "current-tool") private var currentTool: CurrentTool
  @AppStorage("feature.showBrew") private var showBrew = false
  @State private var firebaseService = FirebaseService.shared
  @State private var showingInvitePreview = false
  
  var body: some View {
    Group {
      switch currentTool {
      case .agents: Agents_RootView()
      case .workspaces: Workspaces_RootView()
      case .brew:
        if showBrew {
          Brew_RootView()
        } else {
          Agents_RootView()
        }
      case .repositories: Repositories_RootView()
      case .git: Repositories_RootView(initialScope: .local)
      case .github: Repositories_RootView(initialScope: .remote)
      case .swarm: SwarmStatusView()
      }
    }
    .onAppear {
      if currentTool == .brew && !showBrew {
        currentTool = .agents
      }
      migrateLegacyToolSelectionIfNeeded(currentTool)
    }
    .onChange(of: showBrew) { _, newValue in
      if !newValue && currentTool == .brew {
        currentTool = .agents
      }
    }
    .onChange(of: currentTool) { _, newValue in
      migrateLegacyToolSelectionIfNeeded(newValue)
    }
    .onChange(of: firebaseService.pendingInvitePreview) { _, newValue in
      if newValue != nil {
        showingInvitePreview = true
      }
    }
    .sheet(isPresented: $showingInvitePreview) {
      if let preview = firebaseService.pendingInvitePreview {
        InvitePreviewSheet(preview: preview, firebaseService: firebaseService)
      }
    }
    .task {
      // Populate RepoRegistry from all known local paths on launch
      // so URL-based lookups work everywhere (Review with Agent, etc.)
      await populateRepoRegistry()
    }
  }

  private func migrateLegacyToolSelectionIfNeeded(_ tool: CurrentTool) {
    switch tool {
    case .git:
      UserDefaults.standard.set(Repositories_RootView.Scope.local.rawValue, forKey: "repositories.selectedScope")
      currentTool = .repositories
    case .github:
      UserDefaults.standard.set(Repositories_RootView.Scope.remote.rawValue, forKey: "repositories.selectedScope")
      currentTool = .repositories
    default:
      break
    }
  }

  /// Register all known repo paths with RepoRegistry so any feature can
  /// resolve "GitHub repo → local path" via a single lookup.
  private func populateRepoRegistry() async {
    let registry = RepoRegistry.shared
    // 1. Git tab repos (persisted in AppStorage, always available)
    let gitPaths = Git.ViewModel.shared.repositories.map(\.path)
    await registry.registerAllPaths(gitPaths)
    // 2. ReviewLocally recent repos
    let recentPaths = ReviewLocallyService.shared.recentRepositories.map(\.path)
    await registry.registerAllPaths(recentPaths)
  }
}

#Preview {
  ContentView()
}
