//
//  PersonalView.swift
//  
//
//  Created by Cory Loken on 12/12/21.
//  Modernized to @Observable on 1/5/26
//  Updated for loading states on 1/7/26
//

import SwiftUI

public struct PersonalHeaderView: View {
  @Environment(Github.ViewModel.self) private var viewModel
  @Binding var pullRequests: [Github.PullRequest]
  @Binding var showingMyRequests: Bool
  let allPullRequests: [Github.PullRequest]
  
  public var body: some View {
    HStack {
      Spacer()
      
      Picker("Filter", selection: $showingMyRequests) {
        Text("All").tag(false)
        Text("My Requests").tag(true)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 200)
    }
    .onChange(of: showingMyRequests) { _, showMine in
      withAnimation {
        if showMine {
          pullRequests = allPullRequests.filter { viewModel.hasMe(in: $0.requested_reviewers ?? []) }
        } else {
          pullRequests = allPullRequests
        }
      }
    }
  }
}

public struct PersonalView: View {
  @Environment(Github.ViewModel.self) private var viewModel
  @State private var allPullRequests = [Github.PullRequest]()
  @State private var filteredPullRequests = [Github.PullRequest]()
  @State private var showingMyRequests = false
  @State private var isLoading = true
  @State private var loadingProgress = ""
  
  let organizations: [Github.User]
  
  public init(organizations: [Github.User]) {
    self.organizations = organizations
  }
  
  public var body: some View {
    VStack {
      PersonalHeaderView(
        pullRequests: $filteredPullRequests,
        showingMyRequests: $showingMyRequests,
        allPullRequests: allPullRequests
      )
      .padding(.horizontal)
      
      if isLoading {
        VStack(spacing: 12) {
          ProgressView()
          Text(loadingProgress)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if filteredPullRequests.isEmpty {
        ContentUnavailableView(
          "No Pull Requests",
          systemImage: "arrow.triangle.pull",
          description: Text(showingMyRequests ? "No pull requests assigned to you" : "No open pull requests found")
        )
      } else {
        List {
          ForEach(filteredPullRequests.sorted(by: { $0.updated_at ?? "" > $1.updated_at ?? ""})) { pullRequest in
            VStack {
              NavigationLink(destination: PullRequestDetailView(organization: pullRequest.base.repo.owner, repository: pullRequest.base.repo, pullRequest: pullRequest)) {
                PullRequestsListItemView(pullRequest: pullRequest, organization: pullRequest.base.repo.owner, repository: pullRequest.base.repo, showAvatar: true, showRepository: true)
              }
#if os(macOS)
              Divider()
#endif
            }
          }
        }
      }
    }
    .task {
      await loadPullRequests()
    }
  }
  
  private func loadPullRequests() async {
    isLoading = true
    var newPRs = [Github.PullRequest]()
    
    for organization in organizations {
      loadingProgress = "Loading \(organization.login ?? "organization")..."
      
      do {
        let repositories = try await Github.loadRepositories(organization: organization.login ?? "")
        
        for repository in repositories {
          loadingProgress = "Checking \(repository.name)..."
          let requests = try await Github.pullRequests(from: repository)
          newPRs.append(contentsOf: requests)
        }
      } catch {
        // Continue loading other orgs even if one fails
        continue
      }
    }
    
    allPullRequests = newPRs
    filteredPullRequests = newPRs
    isLoading = false
    loadingProgress = ""
  }
}
