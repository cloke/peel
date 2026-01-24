//
//  PullRequestsView.swift
//  PullRequestsView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import MarkdownUI
import PeelUI

struct PullRequestDetailView: View {
  @Environment(\.recentPRsProvider) private var recentPRsProvider
  @Environment(\.reviewWithAgentProvider) private var reviewWithAgentProvider
  
  let organization: Github.User?
  let repository: Github.Repository
  let pullRequest: Github.PullRequest
  
  #if os(macOS)
  @State private var showingReviewLocally = false
  #endif
  
  var body: some View {
    VStack(alignment: .leading) {
      // Header with title and actions
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(pullRequest.title ?? "")
            .font(.title)
          
          HStack(spacing: 12) {
            Label("#\(pullRequest.number)", systemImage: "number")
            Label(pullRequest.head.ref, systemImage: "arrow.triangle.branch")
            if let state = pullRequest.state {
              Label(state.capitalized, systemImage: state == "open" ? "circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(state == "open" ? .green : .purple)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        #if os(macOS)
        Button {
          showingReviewLocally = true
        } label: {
          Label("Review Locally", systemImage: "arrow.down.to.line.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("github.pullRequest.reviewLocally")
        .help("Create a worktree to review this PR locally")

        Button {
          reviewWithAgentProvider?.reviewWithAgent(pr: pullRequest, repo: repository)
        } label: {
          Label("Review with Agent", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .disabled(reviewWithAgentProvider == nil)
        .accessibilityIdentifier("github.pullRequest.reviewWithAgent")
        .help("Create a worktree and run an agent review")
        #endif
      }
      
      Divider()
      
      Text("Description")
        .font(.headline)
      ScrollView {
        Markdown(Document(stringLiteral: pullRequest.body ?? ""))
      }
      PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
      Spacer()
    }
    .padding()
    .task(id: pullRequest.id) {
      await Task.yield()
      await MainActor.run {
        // Record this PR view after the current render pass
        recentPRsProvider?.recordView(pr: pullRequest, repo: repository)
      }
    }
    #if os(macOS)
    .sheet(isPresented: $showingReviewLocally) {
      ReviewLocallySheet(pullRequest: pullRequest, repository: repository)
    }
    #endif
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
        Divider()
      }
    }
  }
}

public struct PullRequestsView: View {
  public let organization: Github.User
  public let repository: Github.Repository
  
  public init(organization: Github.User, repository: Github.Repository) {
    self.organization = organization
    self.repository = repository
  }
  
  public var body: some View {
    AsyncContentView(
      load: { try await Github.pullRequests(from: repository) },
      content: { pullRequests in
        PullRequestListView(organization: organization, repository: repository, pullRequests: pullRequests)
      },
      emptyView: { EmptyStateView("No Pull Requests", systemImage: "list.bullet") }
    )
    .id(repository.id)
  }
}