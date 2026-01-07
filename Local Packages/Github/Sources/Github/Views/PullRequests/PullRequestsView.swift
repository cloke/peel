//
//  PullRequestsView.swift
//  PullRequestsView
//
//  Created by Cory Loken on 7/15/21.
//  Updated for better empty/error states on 1/7/26
//

import SwiftUI
import MarkdownUI

struct PullRequestDetailView: View {
  let organization: Github.User?
  let repository: Github.Repository
  let pullRequest: Github.PullRequest
  
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(pullRequest.title ?? "Untitled")
        .font(.title)
      
      Divider()
      
      if let body = pullRequest.body, !body.isEmpty {
        Text("Description")
          .font(.headline)
        ScrollView {
          Markdown(Document(stringLiteral: body))
        }
      }
      
      PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
      
      Spacer()
    }
    .padding()
  }
}

struct PullRequestListView: View {
  let organization: Github.User
  let repository: Github.Repository
  let pullRequests: [Github.PullRequest]
  
  var body: some View {
    List {
      ForEach(pullRequests) { pullRequest in
        NavigationLink(destination: PullRequestDetailView(organization: organization, repository: repository, pullRequest: pullRequest)) {
          PullRequestsListItemView(pullRequest: pullRequest, organization: organization, repository: repository)
        }
      }
    }
  }
}

public struct PullRequestsView: View {
  @State private var pullRequests = [Github.PullRequest]()
  @State private var state: LoadingState = .loading
  @State private var errorMessage: String?
  
  public let organization: Github.User
  public let repository: Github.Repository
  
  public init(organization: Github.User, repository: Github.Repository) {
    self.organization = organization
    self.repository = repository
  }
  
  public var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView("Loading pull requests...")
      case .loaded:
        PullRequestListView(organization: organization, repository: repository, pullRequests: pullRequests)
      case .empty:
        ContentUnavailableView(
          "No Pull Requests",
          systemImage: "arrow.triangle.pull",
          description: Text("This repository has no open pull requests")
        )
      }
    }
    .task(id: repository.id) {
      await loadPullRequests()
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
      Button("Retry") { Task { await loadPullRequests() } }
    } message: {
      Text(errorMessage ?? "")
    }
  }
  
  private func loadPullRequests() async {
    state = .loading
    errorMessage = nil
    
    do {
      pullRequests = try await Github.pullRequests(from: repository)
      state = pullRequests.isEmpty ? .empty : .loaded
    } catch {
      errorMessage = "Failed to load pull requests: \(error.localizedDescription)"
      state = .empty
    }
  }
}
