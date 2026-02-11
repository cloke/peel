//
//  PullRequestsView.swift
//  PullRequestsView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import MarkdownUI
import PeelUI

public struct PullRequestDetailView: View {
  @Environment(\.recentPRsProvider) private var recentPRsProvider
  @Environment(\.reviewWithAgentProvider) private var reviewWithAgentProvider

  public let organization: Github.User?
  public let repository: Github.Repository
  public let pullRequest: Github.PullRequest

  #if os(macOS)
  @State private var showingReviewLocally = false
  #endif

  public init(organization: Github.User?, repository: Github.Repository, pullRequest: Github.PullRequest) {
    self.organization = organization
    self.repository = repository
    self.pullRequest = pullRequest
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Header with title and actions
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(pullRequest.title ?? "")
              .font(.title2)

            HStack(spacing: 12) {
              Label("#\(pullRequest.number)", systemImage: "number")
              Label(pullRequest.head.ref, systemImage: "arrow.triangle.branch")
              if let state = pullRequest.state {
                Label(state.capitalized, systemImage: state == "open" ? "circle.fill" : "checkmark.circle.fill")
                  .foregroundStyle(state == "open" ? .green : .purple)
              }
              if pullRequest.draft == true {
                Label("Draft", systemImage: "square.and.pencil")
                  .foregroundStyle(.secondary)
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

        // Metadata
        metadataSection

        // Description
        if let body = pullRequest.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Description")
              .font(.headline)
            Markdown(Document(stringLiteral: body))
          }
        }

        // Actions
        HStack(spacing: 12) {
          if let urlString = pullRequest.html_url, let url = URL(string: urlString) {
            Link(destination: url) {
              Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(.bordered)
          }
        }

        // Reviews
        PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
      }
      .padding()
    }
    .task(id: pullRequest.id) {
      await Task.yield()
      await MainActor.run {
        recentPRsProvider?.recordView(pr: pullRequest, repo: repository)
      }
    }
    #if os(macOS)
    .sheet(isPresented: $showingReviewLocally) {
      ReviewLocallySheet(pullRequest: pullRequest, repository: repository)
    }
    #endif
  }

  // MARK: - Metadata

  @ViewBuilder
  private var metadataSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 16) {
        metadataItem("Author", pullRequest.user?.publicName ?? "Unknown")
        metadataItem("Updated", formattedDate(pullRequest.updated_at))
        metadataItem("Created", formattedDate(pullRequest.created_at))
      }
      HStack(spacing: 16) {
        metadataItem("Commits", pullRequest.commits.map(String.init) ?? "–")
        metadataItem("Files", pullRequest.changed_files.map(String.init) ?? "–")
        metadataItem("+/-", diffSummary)
      }
      let reviewers = (pullRequest.requested_reviewers ?? []).map { $0.publicName }.filter { !$0.isEmpty }
      if !reviewers.isEmpty {
        metadataItem("Reviewers", reviewers.joined(separator: ", "))
      }
      let labels = (pullRequest.labels ?? []).map { $0.name }.filter { !$0.isEmpty }
      if !labels.isEmpty {
        metadataItem("Labels", labels.joined(separator: ", "))
      }
    }
  }

  private func metadataItem(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout)
    }
  }

  private func formattedDate(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "–" }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return value
  }

  private var diffSummary: String {
    let additions = pullRequest.additions ?? 0
    let deletions = pullRequest.deletions ?? 0
    if additions == 0 && deletions == 0 { return "–" }
    return "+\(additions) / -\(deletions)"
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