//
//  ContentView.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 6/10/22.
//  Updated for unified repositories on iOS
//

import SwiftUI

/// Available tools for iOS — matches macOS 2-tab layout
enum iOSTool: String, CaseIterable, Identifiable {
  case repositories = "Repositories"
  case activity = "Activity"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .repositories: "tray.full.fill"
    case .activity: "bolt.fill"
    }
  }
}

/// Entry point for iOS — 2-tab layout matching macOS
struct ContentView: View {
  @State private var selectedTool: iOSTool = .repositories

  var body: some View {
    TabView(selection: $selectedTool) {
      Tab(iOSTool.repositories.rawValue, systemImage: iOSTool.repositories.icon, value: .repositories) {
        iOSRepositoriesView()
      }

      Tab(iOSTool.activity.rawValue, systemImage: iOSTool.activity.icon, value: .activity) {
        iOSActivityView()
      }
    }
  }
}

// MARK: - iOS Repositories View

/// Repositories tab for iOS. NavigationSplitView with sidebar list + detail.
struct iOSRepositoriesView: View {
  @Environment(RepositoryAggregator.self) private var aggregator
  @State private var selectedRepoId: UUID?
  @State private var searchText = ""

  private var filteredRepos: [UnifiedRepository] {
    if searchText.isEmpty {
      return aggregator.repositories
    }
    return aggregator.repositories.filter {
      $0.displayName.localizedCaseInsensitiveContains(searchText)
        || ($0.ownerSlashRepo?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
  }

  var body: some View {
    NavigationSplitView {
      List(filteredRepos, selection: $selectedRepoId) { repo in
        RepoSidebarRow(repo: repo)
          .tag(repo.id)
      }
      .searchable(text: $searchText, prompt: "Filter repositories")
      .navigationTitle("Repositories")
      .refreshable {
        aggregator.rebuild()
      }
    } detail: {
      if let repoId = selectedRepoId,
         let repo = aggregator.repositoryById[repoId] {
        RepoDetailView(repo: repo)
      } else {
        ContentUnavailableView {
          Label("Select a Repository", systemImage: "tray.full")
        } description: {
          Text("Choose a repository from the sidebar to view details, pull requests, and branches.")
        }
      }
    }
  }
}

// MARK: - iOS Activity View

/// Activity tab for iOS. Placeholder until Firebase is linked for iOS.
struct iOSActivityView: View {
  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Activity", systemImage: "bolt.fill")
      } description: {
        Text("Agent activity, swarm monitoring, and chain status will appear here. Currently available on macOS.")
      }
      .navigationTitle("Activity")
    }
  }
}

#Preview {
  ContentView()
}
