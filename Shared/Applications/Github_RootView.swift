//
//  Github_RootView.swift
//  KitchenSync (macOS)
//
//  Created by Cory Loken on 7/14/21.
//  Modernized to @Observable on 1/5/26
//  Updated for Keychain storage on 1/6/26
//

import SwiftUI
import SwiftData
import Github

struct Github_RootView: View {
  @Environment(\.modelContext) private var modelContext
  @State public var viewModel = Github.ViewModel()
  @State private var dataProvider: GitHubDataProvider?
  
  @State private var organizations = [Github.User]()
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var hasToken = false
  @State private var isLoading = false
  @State private var errorMessage: String?
  @AppStorage("github-show-archived") private var showArchivedRepos = false
  
  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List {
        // Favorites section
        if let provider = dataProvider, !provider.getFavorites().isEmpty {
          Section("Favorites") {
            ForEach(provider.getFavorites()) { favorite in
              NavigationLink(destination: FavoriteRepositoryDestination(favorite: favorite)) {
                HStack {
                  Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(favorite.repoName)
                      .font(.callout)
                    Text(favorite.ownerLogin)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
        
        // Recent PRs section
        if let provider = dataProvider, !provider.getRecentPRs().isEmpty {
          Section("Recent PRs") {
            ForEach(provider.getRecentPRs().prefix(5)) { recent in
              NavigationLink(destination: RecentPRDestination(recentPR: recent)) {
                HStack {
                  Image(systemName: recent.state == "open" ? "circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(recent.state == "open" ? .green : .purple)
                    .font(.caption)
                  VStack(alignment: .leading, spacing: 2) {
                    Text("#\(recent.prNumber) \(recent.title)")
                      .font(.callout)
                      .lineLimit(1)
                    Text(recent.repoFullName)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
        
        if isLoading {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowBackground(Color.clear)
        } else if let error = errorMessage {
          Section {
            VStack(spacing: 12) {
              Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
              Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
              Button("Retry") {
                Task {
                  isLoading = true
                  errorMessage = nil
                  defer { isLoading = false }
                  do {
                    viewModel.me = try await Github.me()
                    organizations = try await Github.loadOrganizations()
                  } catch {
                    errorMessage = "Failed to load: \(error.localizedDescription)"
                  }
                }
              }
              .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
          }
          .listRowBackground(Color.clear)
        } else if hasToken && viewModel.me != nil {
          Section("Organizations") {
            ForEach(organizations) { organization in
              OrganizationRepositoryView(organization: organization)
            }
          }
        } else if hasToken {
          // Token exists but user data not loaded yet - show loading
          HStack {
            Spacer()
            ProgressView("Loading profile...")
            Spacer()
          }
          .listRowBackground(Color.clear)
        } else {
          Button("Login") {
            Task {
              isLoading = true
              errorMessage = nil
              defer { isLoading = false }
              do {
                try await Github.authorize()
                viewModel.me = try await Github.me()
                organizations = try await Github.loadOrganizations()
                hasToken = await Github.hasToken
              } catch {
                print("Login error: \(error)")
                errorMessage = "Login failed: \(error.localizedDescription)"
              }
            }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        // User profile pinned to bottom
        if hasToken, let me = viewModel.me {
          VStack(spacing: 0) {
            Divider()
            NavigationLink(destination: PersonalView(organizations: organizations)) {
              ProfileNameView(me: me)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 10)
          }
          .background(Color(nsColor: .windowBackgroundColor))
        }
      }
      .task {
        hasToken = await Github.hasToken
        if hasToken {
          isLoading = true
          errorMessage = nil
          defer { isLoading = false }
          do {
            viewModel.me = try await Github.me()
            organizations = try await Github.loadOrganizations()
          } catch {
            print("Error loading user data: \(error)")
            // Don't logout on network errors - just show error
            errorMessage = "Failed to load: \(error.localizedDescription)"
          }
        }
      }
    } detail: {
      Text("Select an organization or repository")
        .foregroundStyle(.secondary)
    }
    .navigationSplitViewStyle(.balanced)
    .environment(viewModel)
    .favoritesProvider(dataProvider)
    .recentPRsProvider(dataProvider)
    .onAppear {
      dataProvider = GitHubDataProvider(modelContext: modelContext)
    }
    .frame(idealHeight: 400)
    .toolbar {
#if os(macOS)
      ToolSelectionToolbar()
#endif
      ToolbarItem(placement: .navigation) {
        Menu {
          Toggle("Show Archived Repos", isOn: $showArchivedRepos)
          Divider()
          Button {
            Task {
              await Github.reauthorize()
              hasToken = false
              viewModel.me = nil
              organizations = []
            }
          } label: {
            Text("Logout")
            Image(systemName: "figure.wave")
          }
        } label: {
          Image(systemName: "gear")
        }
      }
    }
  }
}

// MARK: - Destination Views

/// Loads and displays a favorited repository
struct FavoriteRepositoryDestination: View {
  let favorite: FavoriteRepository
  
  @State private var repository: Github.Repository?
  @State private var owner: Github.User?
  @State private var isLoading = true
  @State private var error: String?
  
  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading repository...")
      } else if let error {
        VStack {
          Text("Failed to load repository")
            .font(.headline)
          Text(error)
            .foregroundStyle(.secondary)
          Button("Retry") {
            Task { await loadRepository() }
          }
        }
      } else if let repository, let owner {
        RepositoryContainerView(organization: owner, repository: repository)
      }
    }
    .task {
      await loadRepository()
    }
  }
  
  private func loadRepository() async {
    isLoading = true
    error = nil
    do {
      async let repoTask = Github.repository(owner: favorite.ownerLogin, name: favorite.repoName)
      async let ownerTask = Github.user(login: favorite.ownerLogin)
      (repository, owner) = try await (repoTask, ownerTask)
    } catch {
      self.error = error.localizedDescription
    }
    isLoading = false
  }
}

/// Loads and displays a recent PR
struct RecentPRDestination: View {
  let recentPR: RecentPRInfo
  
  @State private var isLoading = true
  @State private var error: String?
  
  var body: some View {
    Group {
      if isLoading {
        ProgressView("Loading PR...")
      } else if let error {
        VStack {
          Text("Failed to load PR")
            .font(.headline)
          Text(error)
            .foregroundStyle(.secondary)
        }
      } else {
        VStack(spacing: 16) {
          Text("#\(recentPR.prNumber)")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text(recentPR.title)
            .font(.title2)
          Text(recentPR.repoFullName)
            .foregroundStyle(.secondary)
          
          if let urlString = recentPR.htmlURL, let url = URL(string: urlString) {
            Link(destination: url) {
              Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
          }
        }
        .padding()
      }
    }
    .task {
      isLoading = false
    }
  }
}

#Preview {
  Github_RootView()
}
