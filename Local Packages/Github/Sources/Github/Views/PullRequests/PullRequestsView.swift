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
  @Environment(\.prReviewStatusProvider) private var prReviewStatusProvider

  public let organization: Github.User?
  public let repository: Github.Repository
  public let initialPullRequest: Github.PullRequest

  /// Live PR data, refreshed on appear
  @State private var pullRequest: Github.PullRequest
  @State private var checkStatus: Github.AggregatedCheckStatus?
  @State private var isLoadingChecks = true
  @State private var reviews = [Github.Review]()
  @State private var currentUserLogin: String?

  @State private var showingReviewSheet = false
  @State private var reviewAction: ReviewAction = .approve
  @State private var reviewBody = ""
  @State private var isSubmittingReview = false
  @State private var reviewSubmitError: String?
  @State private var isMerging = false
  @State private var mergeError: String?
  @State private var showMergeConfirm = false

  #if os(macOS)
  @State private var showingReviewLocally = false
  #endif

  enum ReviewAction: String, CaseIterable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"

    var label: String {
      switch self {
      case .approve: "Approve"
      case .requestChanges: "Request Changes"
      case .comment: "Comment"
      }
    }

    var icon: String {
      switch self {
      case .approve: "checkmark.circle"
      case .requestChanges: "exclamationmark.triangle"
      case .comment: "text.bubble"
      }
    }

    var tint: Color {
      switch self {
      case .approve: .green
      case .requestChanges: .orange
      case .comment: .blue
      }
    }
  }

  public init(organization: Github.User?, repository: Github.Repository, pullRequest: Github.PullRequest) {
    self.organization = organization
    self.repository = repository
    self.initialPullRequest = pullRequest
    self._pullRequest = State(initialValue: pullRequest)
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // MARK: - Header
        headerSection

        // MARK: - Status bar (state + checks summary)
        statusBar

        // MARK: - Metadata grid
        metadataGrid

        // MARK: - CI Checks
        checksSection

        // MARK: - Changed Files
        #if os(macOS)
        changedFilesSection
        #endif

        // MARK: - Review Actions
        #if os(macOS)
        if pullRequest.state == "open" {
          reviewActionsSection
        }
        #endif

        // MARK: - Reviews
        reviewsSection

        // MARK: - Comments
        commentsSection

        // MARK: - Description
        descriptionSection


      }
      .padding()
    }
    .sheet(isPresented: $showingReviewSheet) {
      reviewSheet
    }
    .alert("Merge Pull Request", isPresented: $showMergeConfirm) {
      Button("Merge", role: .destructive) { Task { await mergePR() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Merge #\(pullRequest.number) into \(pullRequest.base.ref)?")
    }
    .task(id: initialPullRequest.id) {
      await Task.yield()
      await MainActor.run {
        recentPRsProvider?.recordView(pr: pullRequest, repo: repository)
      }
      // Refresh PR data to get current state (merged, closed, etc.)
      await refreshPullRequest()
      await loadCheckStatus()
      await loadReviews()
      if currentUserLogin == nil {
        currentUserLogin = try? await Github.me().login
      }
    }
    #if os(macOS)
    .sheet(isPresented: $showingReviewLocally) {
      ReviewLocallySheet(pullRequest: pullRequest, repository: repository)
    }
    #endif
  }

  // MARK: - Header

  @ViewBuilder
  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text(pullRequest.title ?? "")
          .font(.title2)
          .fontWeight(.semibold)

        Spacer()

        HStack(spacing: 8) {
          if let urlString = pullRequest.html_url, let url = URL(string: urlString) {
            Link(destination: url) {
              Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }

          #if os(macOS)
          Button {
            showingReviewLocally = true
          } label: {
            Label("Review Locally", systemImage: "arrow.down.to.line.circle")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("github.pullRequest.reviewLocally")
          .help("Create a worktree to review this PR locally")

          Button {
            reviewWithAgentProvider?.reviewWithAgent(pr: pullRequest, repo: repository)
          } label: {
            Label("Review with Agent", systemImage: "sparkles")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(reviewWithAgentProvider == nil)
          .accessibilityIdentifier("github.pullRequest.reviewWithAgent")
          .help("Create a worktree and run an agent review")
          #endif
        }
      }

      HStack(spacing: 8) {
        Text(verbatim: "#\(pullRequest.number)")
          .fontDesign(.monospaced)

        Text("·")
          .foregroundStyle(.tertiary)

        Label(pullRequest.head.ref, systemImage: "arrow.triangle.branch")

        if pullRequest.draft == true {
          Text("·")
            .foregroundStyle(.tertiary)
          Label("Draft", systemImage: "square.and.pencil")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Status Bar

  @ViewBuilder
  private var statusBar: some View {
    HStack(spacing: 12) {
      // PR state pill
      if let state = pullRequest.state {
        HStack(spacing: 4) {
          Image(systemName: stateIcon(for: state))
          Text(stateLabel(for: state))
            .fontWeight(.medium)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(stateColor(for: state).opacity(0.15))
        .foregroundStyle(stateColor(for: state))
        .clipShape(Capsule())
      }

      // Checks summary pill
      if isLoadingChecks {
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text("Loading checks...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let status = checkStatus, status.total > 0 {
        HStack(spacing: 4) {
          Image(systemName: checksOverallIcon(status.overallState))
          Text(checksSummaryText(status))
            .fontWeight(.medium)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(checksOverallColor(status.overallState).opacity(0.15))
        .foregroundStyle(checksOverallColor(status.overallState))
        .clipShape(Capsule())
      }

      Spacer()

      // Agent review status pill
      if let status = agentReviewStatus {
        HStack(spacing: 4) {
          if status.isActive {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: status.systemImage)
          }
          Text(status.displayName)
            .fontWeight(.medium)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(status.badgeColor.opacity(0.15))
        .foregroundStyle(status.badgeColor)
        .clipShape(Capsule())
      }

      // Author
      if let author = pullRequest.user {
        HStack(spacing: 6) {
          AvatarView(url: URL(string: author.avatar_url), maxWidth: 20, maxHeight: 20)
            .frame(width: 20, height: 20)
          Text(author.publicName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Metadata Grid

  @ViewBuilder
  private var metadataGrid: some View {
    let columns = [
      GridItem(.flexible(), spacing: 12),
      GridItem(.flexible(), spacing: 12),
      GridItem(.flexible(), spacing: 12),
      GridItem(.flexible(), spacing: 12)
    ]

    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
      MetadataCell(label: "Commits", value: pullRequest.commits.map(String.init) ?? "–", icon: "point.3.connected.trianglepath.dotted")
      MetadataCell(label: "Files", value: pullRequest.changed_files.map(String.init) ?? "–", icon: "doc")
      MetadataCell(label: "Additions", value: pullRequest.additions.map { "+\($0)" } ?? "–", icon: "plus", tint: .green)
      MetadataCell(label: "Deletions", value: pullRequest.deletions.map { "-\($0)" } ?? "–", icon: "minus", tint: .red)
    }
    .padding(12)
    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))

    // Labels & reviewers
    VStack(alignment: .leading, spacing: 8) {
      if let labels = pullRequest.labels, !labels.isEmpty {
        HStack(spacing: 4) {
          Text("Labels")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)
          HStack(spacing: 4) {
            ForEach(labels) { label in
              let color = Color.init(hex: label.color)
              Text(label.name)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color)
                .foregroundColor(color.isDarkColor ? .white : .black)
                .clipShape(Capsule())
            }
          }
        }
      }

      if let reviewers = pullRequest.requested_reviewers, !reviewers.isEmpty {
        HStack(spacing: 4) {
          Text("Reviewers")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)
          HStack(spacing: -4) {
            ForEach(reviewers) { reviewer in
              AvatarView(url: URL(string: reviewer.avatar_url), maxWidth: 20, maxHeight: 20)
                .frame(width: 20, height: 20)
                .help(reviewer.publicName)
            }
          }
          Text(reviewers.map(\.publicName).joined(separator: ", "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        }
      }
    }

    // Dates
    HStack(spacing: 16) {
      HStack(spacing: 4) {
        Image(systemName: "calendar.badge.plus")
          .foregroundStyle(.secondary)
        Text("Created \(formattedDate(pullRequest.created_at))")
      }
      HStack(spacing: 4) {
        Image(systemName: "calendar.badge.clock")
          .foregroundStyle(.secondary)
        Text("Updated \(formattedDate(pullRequest.updated_at))")
      }
      if pullRequest.merged_at != nil {
        HStack(spacing: 4) {
          Image(systemName: "arrow.triangle.merge")
            .foregroundStyle(.purple)
          Text("Merged \(formattedDate(pullRequest.merged_at))")
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  // MARK: - Checks Section

  @ViewBuilder
  private var checksSection: some View {
    if let status = checkStatus, !status.checks.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Checks")
          .font(.headline)

        VStack(spacing: 4) {
          ForEach(status.checks) { check in
            HStack(spacing: 8) {
              Image(systemName: checkItemIcon(check.state))
                .font(.caption)
                .foregroundStyle(checkItemColor(check.state))
                .frame(width: 16)

              Text(check.name)
                .font(.callout)

              Spacer()

              checkItemBadge(check.state)
            }
            .padding(.vertical, 2)
          }
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  // MARK: - Changed Files

  #if os(macOS)
  @ViewBuilder
  private var changedFilesSection: some View {
    let owner = organization?.login ?? repository.owner?.login ?? ""
    PRChangedFilesView(owner: owner, repo: repository.name, pullNumber: pullRequest.number)
  }
  #endif

  // MARK: - Reviews Section

  @ViewBuilder
  private var reviewsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Reviews")
        .font(.headline)

      PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
  }

  // MARK: - Comments Section

  @ViewBuilder
  private var commentsSection: some View {
    let owner = organization?.login ?? repository.owner?.login ?? ""
    PRCommentsView(owner: owner, repo: repository.name, pullNumber: pullRequest.number)
  }

  // MARK: - Description

  @ViewBuilder
  private var descriptionSection: some View {
    if let body = pullRequest.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Description")
          .font(.headline)

        Markdown(Document(stringLiteral: body))
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  // MARK: - Agent Review Status

  private var agentReviewStatus: PRAgentReviewStatus? {
    guard let owner = organization?.login ?? repository.owner?.login else { return nil }
    return prReviewStatusProvider?.reviewStatus(
      owner: owner, repo: repository.name, prNumber: pullRequest.number
    )
  }

  // MARK: - Review Actions Section

  #if os(macOS)
  @ViewBuilder
  private var reviewActionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Actions")
        .font(.headline)

      HStack(spacing: 8) {
        Button {
          reviewAction = .approve
          reviewBody = ""
          showingReviewSheet = true
        } label: {
          Label("Approve", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.small)
        .disabled(currentUserApproved)
        .help(currentUserApproved ? "You've already approved this PR" : "Approve this PR")

        Button {
          reviewAction = .requestChanges
          reviewBody = ""
          showingReviewSheet = true
        } label: {
          Label("Request Changes", systemImage: "exclamationmark.triangle")
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .controlSize(.small)

        Button {
          reviewAction = .comment
          reviewBody = ""
          showingReviewSheet = true
        } label: {
          Label("Comment", systemImage: "text.bubble")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer()

        if pullRequest.merged_at == nil {
          Button {
            showMergeConfirm = true
          } label: {
            Label(isMerging ? "Merging\u{2026}" : "Merge", systemImage: "arrow.triangle.merge")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
          .disabled(isMerging)
        }
      }

      if let error = reviewSubmitError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }
      if let error = mergeError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }
  #endif

  // MARK: - Review Sheet

  @ViewBuilder
  private var reviewSheet: some View {
    VStack(spacing: 16) {
      HStack {
        Image(systemName: reviewAction.icon)
          .foregroundStyle(reviewAction.tint)
        Text(reviewAction.label)
          .font(.headline)
        Spacer()
        Button("Cancel") { showingReviewSheet = false }
          .buttonStyle(.plain)
      }

      Text(verbatim: "\(repository.name) #\(pullRequest.number)")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      TextEditor(text: $reviewBody)
        .font(.body)
        .frame(minHeight: 120)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(.quaternary, lineWidth: 1)
        )

      if let error = reviewSubmitError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button {
          Task { await submitReview() }
        } label: {
          if isSubmittingReview {
            ProgressView()
              .controlSize(.small)
          } else {
            Label("Submit \(reviewAction.label)", systemImage: reviewAction.icon)
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(reviewAction.tint)
        .disabled(isSubmittingReview || (reviewAction == .requestChanges && reviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
      }
    }
    .padding(20)
    .frame(minWidth: 450, minHeight: 250)
  }

  // MARK: - Submit Review

  private func submitReview() async {
    guard let owner = organization?.login ?? repository.owner?.login else { return }
    isSubmittingReview = true
    reviewSubmitError = nil
    defer { isSubmittingReview = false }

    do {
      _ = try await Github.createPullRequestReview(
        owner: owner,
        repository: repository.name,
        number: pullRequest.number,
        event: reviewAction.rawValue,
        body: reviewBody
      )
      showingReviewSheet = false
      await refreshPullRequest()
      await loadReviews()
    } catch {
      reviewSubmitError = error.localizedDescription
    }
  }

  // MARK: - Merge PR

  private func mergePR() async {
    guard let owner = organization?.login ?? repository.owner?.login else { return }
    isMerging = true
    mergeError = nil
    defer { isMerging = false }

    do {
      let result = try await Github.mergePullRequest(
        owner: owner,
        repository: repository.name,
        number: pullRequest.number
      )
      if result.merged == true {
        await refreshPullRequest()
      } else {
        mergeError = result.message ?? "Merge failed"
      }
    } catch {
      mergeError = error.localizedDescription
    }
  }

  // MARK: - Helpers

  private func refreshPullRequest() async {
    guard let owner = organization?.login ?? repository.owner?.login else { return }
    if let fresh = try? await Github.pullRequest(owner: owner, repository: repository.name, number: pullRequest.number) {
      pullRequest = fresh
    }
  }

  private func loadCheckStatus() async {
    isLoadingChecks = true
    defer { isLoadingChecks = false }

    guard let owner = organization?.login ?? repository.owner?.login else { return }
    let ref = pullRequest.head.sha

    checkStatus = try? await Github.aggregatedCheckStatus(owner: owner, repo: repository.name, ref: ref)
  }

  private func loadReviews() async {
    let owner = organization?.login ?? repository.owner?.login ?? ""
    reviews = (try? await Github.loadReviews(organization: owner, repository: repository.name, pullNumber: pullRequest.number)) ?? []
  }

  private var currentUserApproved: Bool {
    guard let login = currentUserLogin else { return false }
    // Check the most recent review per user (same dedup logic as the row view)
    return reviews.last { ($0.user.login ?? "") == login }?.state == "APPROVED"
  }

  private func stateIcon(for state: String) -> String {
    switch state {
    case "open": "circle.fill"
    case "closed": pullRequest.merged_at != nil ? "arrow.triangle.merge" : "xmark.circle.fill"
    default: "circle"
    }
  }

  private func stateLabel(for state: String) -> String {
    if state == "closed" && pullRequest.merged_at != nil { return "Merged" }
    return state.capitalized
  }

  private func stateColor(for state: String) -> Color {
    switch state {
    case "open": .green
    case "closed" where pullRequest.merged_at != nil: .purple
    case "closed": .red
    default: .secondary
    }
  }

  private func checksOverallIcon(_ state: Github.AggregatedCheckStatus.OverallState) -> String {
    switch state {
    case .success: "checkmark.circle.fill"
    case .failure: "xmark.circle.fill"
    case .pending: "clock.fill"
    case .none: "circle"
    }
  }

  private func checksOverallColor(_ state: Github.AggregatedCheckStatus.OverallState) -> Color {
    switch state {
    case .success: .green
    case .failure: .red
    case .pending: .orange
    case .none: .secondary
    }
  }

  private func checksSummaryText(_ status: Github.AggregatedCheckStatus) -> String {
    switch status.overallState {
    case .success: "\(status.passed)/\(status.total) checks passed"
    case .failure: "\(status.failed) failed · \(status.passed) passed"
    case .pending: "\(status.pending) pending · \(status.passed) passed"
    case .none: "No checks"
    }
  }

  private func checkItemIcon(_ state: Github.CheckItemState) -> String {
    switch state {
    case .success: "checkmark.circle.fill"
    case .failure: "xmark.circle.fill"
    case .pending: "clock.fill"
    case .neutral: "minus.circle.fill"
    case .skipped: "chevron.right.2"
    }
  }

  private func checkItemColor(_ state: Github.CheckItemState) -> Color {
    switch state {
    case .success: .green
    case .failure: .red
    case .pending: .orange
    case .neutral, .skipped: .secondary
    }
  }

  @ViewBuilder
  private func checkItemBadge(_ state: Github.CheckItemState) -> some View {
    let label: String = switch state {
    case .success: "Passed"
    case .failure: "Failed"
    case .pending: "Pending"
    case .neutral: "Neutral"
    case .skipped: "Skipped"
    }
    Text(label)
      .font(.caption2)
      .foregroundStyle(checkItemColor(state))
  }

  private func formattedDate(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "–" }
    if let date = GithubDateParser.parse(value) {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return value
  }
}

private struct MetadataCell: View {
  let label: String
  let value: String
  let icon: String
  var tint: Color = .secondary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .foregroundStyle(tint)
        Text(label)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)

      Text(value)
        .font(.title3)
        .fontWeight(.semibold)
        .fontDesign(.monospaced)
    }
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