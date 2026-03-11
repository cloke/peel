//
//  PullRequestReviewRowView.swift
//  PullRequestReviewRowView
//
//  Created by Cory Loken on 7/20/21.
//

import SwiftUI
import MarkdownUI

struct PullRequestReviewRowView: View {
  let organization: Github.User?
  let repository: Github.Repository
  let pullNumber: Int

  @State private var reviews = [Github.Review]()
  @State private var expandedReviewIds = Set<Int>()
  @State private var isLoading = true
  @State private var error: String?

  private var owner: String {
    organization?.login ?? repository.owner?.login ?? ""
  }

  var body: some View {
    if isLoading && reviews.isEmpty {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Loading reviews...")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .task { await loadReviews() }
    } else if let error, reviews.isEmpty {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if reviews.isEmpty {
      HStack(spacing: 6) {
        Image(systemName: "person.badge.clock")
          .foregroundStyle(.tertiary)
        Text("No reviews yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(deduplicatedReviews) { review in
          VStack(alignment: .leading, spacing: 6) {
            Button {
              withAnimation(.easeInOut(duration: 0.2)) {
                if expandedReviewIds.contains(review.id) {
                  expandedReviewIds.remove(review.id)
                } else {
                  expandedReviewIds.insert(review.id)
                }
              }
            } label: {
              HStack(spacing: 10) {
                AvatarView(url: URL(string: review.user.avatar_url), maxWidth: 24, maxHeight: 24)
                  .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                  Text(review.user.publicName)
                    .font(.callout)
                  if !review.body.isEmpty && !expandedReviewIds.contains(review.id) {
                    Text(review.body)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                }

                Spacer()

                ReviewStateBadge(state: review.state)

                if !review.body.isEmpty {
                  Image(systemName: expandedReviewIds.contains(review.id) ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
              }
            }
            .buttonStyle(.plain)

            if expandedReviewIds.contains(review.id) && !review.body.isEmpty {
              Markdown(Document(stringLiteral: review.body))
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
          }

          if review.id != deduplicatedReviews.last?.id {
            Divider()
          }
        }
      }
      .task { await loadReviews() }
    }
  }

  private func loadReviews() async {
    defer { isLoading = false }
    do {
      reviews = try await Github.loadReviews(organization: owner, repository: repository.name, pullNumber: pullNumber)
      error = nil
    } catch {
      if reviews.isEmpty {
        self.error = "Failed to load reviews: \(error.localizedDescription)"
      }
    }
  }

  /// Show only the most recent review per user
  private var deduplicatedReviews: [Github.Review] {
    var seen = Set<String>()
    var result = [Github.Review]()
    for review in reviews.reversed() {
      let key = review.user.login ?? review.user.avatar_url
      if !seen.contains(key) {
        seen.insert(key)
        result.append(review)
      }
    }
    return result.reversed()
  }
}

private struct ReviewStateBadge: View {
  let state: String

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption2)
      Text(label)
        .font(.caption2)
        .fontWeight(.medium)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(color.opacity(0.15))
    .foregroundStyle(color)
    .clipShape(Capsule())
  }

  private var icon: String {
    switch state {
    case "APPROVED": "checkmark"
    case "CHANGES_REQUESTED": "xmark"
    case "COMMENTED": "text.bubble"
    case "DISMISSED": "minus"
    default: "ellipsis"
    }
  }

  private var label: String {
    switch state {
    case "APPROVED": "Approved"
    case "CHANGES_REQUESTED": "Changes"
    case "COMMENTED": "Commented"
    case "DISMISSED": "Dismissed"
    default: state.capitalized
    }
  }

  private var color: Color {
    switch state {
    case "APPROVED": .green
    case "CHANGES_REQUESTED": .orange
    case "COMMENTED": .blue
    case "DISMISSED": .secondary
    default: .secondary
    }
  }
}
