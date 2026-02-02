//
//  ContentView.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//

import SwiftUI
import Git

enum CurrentTool: String, Identifiable, CaseIterable {
  case agents = "agents", workspaces = "workspaces", brew = "brew", git = "git", github = "github", swarm = "swarm"
  var id: String { rawValue }
}

/// Entry point for MacOS
struct ContentView: View {
  @AppStorage(wrappedValue: .brew, "current-tool") private var currentTool: CurrentTool
  @State private var firebaseService = FirebaseService.shared
  @State private var showingInvitePreview = false
  
  var body: some View {
    Group {
      switch currentTool {
      case .agents: Agents_RootView()
      case .workspaces: Workspaces_RootView()
      case .brew: Brew_RootView()
      case .git: Git_RootView()
      case .github: Github_RootView()
      case .swarm: SwarmStatusView()
      }
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
  }
}

#Preview {
  ContentView()
}
