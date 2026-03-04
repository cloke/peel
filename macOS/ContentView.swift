//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Combine
import Git
import Github

enum CurrentTool: String, Identifiable, CaseIterable {
  case repositories = "repositories"
  case activity = "activity"
  // Legacy cases — kept for AppStorage migration, auto-redirect on appear
  case agents = "agents"
  case workspaces = "workspaces"
  case brew = "brew"
  case git = "git"
  case github = "github"
  case swarm = "swarm"
  var id: String { rawValue }
}

/// Entry point for MacOS
struct ContentView: View {
  @AppStorage(wrappedValue: .repositories, "current-tool") private var currentTool: CurrentTool
  @AppStorage("feature.showBrew") private var showBrew = false
  @AppStorage("onboarding.checklistDismissed") private var checklistDismissed = false
  @State private var firebaseService = FirebaseService.shared
  @State private var showingInvitePreview = false
  @State private var showChecklist = false
  @State private var showCommandPalette = false
  @State private var activeLabFeature: LabFeature?
  
  var body: some View {
    Group {
      switch currentTool {
      case .repositories: UnifiedRepositoriesView()
      case .activity: ActivityDashboardView()
      // Legacy routes — redirect on appear, show new view immediately
      case .agents, .workspaces, .swarm: ActivityDashboardView()
      case .brew:
        if showBrew {
          Brew_RootView()
        } else {
          UnifiedRepositoriesView()
        }
      case .git, .github: UnifiedRepositoriesView()
      }
    }
    .onAppear {
      migrateLegacyToolSelectionIfNeeded(currentTool)
      if !checklistDismissed {
        showChecklist = true
      }
    }
    .onChange(of: showBrew) { _, newValue in
      if !newValue && currentTool == .brew {
        currentTool = .repositories
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
    .sheet(isPresented: $showChecklist) {
      FeatureDiscoveryChecklistView()
    }
    .sheet(item: $activeLabFeature) { feature in
      LabFeatureSheetContent(feature: feature)
    }
    .overlay {
      if showCommandPalette {
        ZStack {
          Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture { showCommandPalette = false }

          CommandPaletteView(isPresented: $showCommandPalette)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(.spring(response: 0.25), value: showCommandPalette)
      }
    }
    .toolbar {
      if !checklistDismissed {
        ToolbarItem(placement: .automatic) {
          Button {
            showChecklist = true
          } label: {
            Image(systemName: "checklist")
          }
          .help("Feature Discovery Checklist")
        }
      }
      LabsToolbarItem(activeLabFeature: $activeLabFeature)
    }
    .onReceive(NotificationCenter.default.publisher(for: .openCommandPalette)) { _ in
      showCommandPalette.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .navigateToTool)) { notification in
      if let tool = notification.object as? CurrentTool {
        currentTool = tool
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
    case .agents, .workspaces, .swarm:
      currentTool = .activity
    case .git, .github:
      currentTool = .repositories
    case .brew:
      if !showBrew { currentTool = .repositories }
    case .repositories, .activity:
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
