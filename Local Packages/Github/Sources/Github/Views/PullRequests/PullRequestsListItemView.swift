//
//  PullRequestsListItemView.swift
//  PullRequestsListItemView
//
//  Created by Cory Loken on 7/20/21.
//  Modernized to @Observable on 1/5/26
//

import PeelUI
import SwiftUI

struct PullRequestsListItemView: View {
  @Environment(Github.ViewModel.self) private var viewModel
  let pullRequest: Github.PullRequest
  let organization: Github.User?
  let repository: Github.Repository
  var showAvatar = false
  var showRepository = false

  @State private var reviews = [Github.Review]()
  
  var prState: String {
    let state = reviews.reduce(into: "Open") { result, review in
      switch review.state {
      case "APPROVED":
        result = "Approved"
      case "CHANGES_REQUESTED":
        result = "Changes Requested"
      default:
        result = "Discussing"
      }
    }

    if state == "Open", let comments = pullRequest.comments, comments > 0 {
      return "Discussing"
    }
    
    return state
  }

  private var stateColor: Color {
    switch prState {
    case "Approved": .green
    case "Changes Requested": .orange
    case "Discussing": .blue
    default: .secondary
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Left icon — fixed size, always aligned
      if showAvatar {
        AvatarView(url: URL(string: organization?.avatar_url ?? ""), maxWidth: 32, maxHeight: 32)
          .frame(width: 32, height: 32)
      } else {
        Image(systemName: "arrow.triangle.pull")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
          .background(.quaternary, in: Circle())
      }

      // Main content
      VStack(alignment: .leading, spacing: 4) {
        // Title row
        Text(pullRequest.title ?? "")
          .font(.body)
          .lineLimit(2)

        // Labels
        if let labels = pullRequest.labels, !labels.isEmpty {
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

        // Bottom row: repo + date on the left, status badge on the right
        HStack(alignment: .center) {
          HStack(spacing: 4) {
            if showRepository {
              Text(repository.name)
                .foregroundStyle(.secondary)
            }
            Text(pullRequest.dateFormatted)
              .foregroundStyle(.tertiary)
          }
          .font(.caption)

          Spacer()

          // Reviewer avatars
          if let reviewers = pullRequest.requested_reviewers, !reviewers.isEmpty {
            HStack(spacing: -4) {
              ForEach(reviewers.prefix(4)) {
                AvatarView(url: URL(string: $0.avatar_url), maxWidth: 16, maxHeight: 16)
                  .frame(width: 16, height: 16)
              }
            }
          }

          // Status badge
          Text(prState)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateColor.opacity(0.15))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
        }

        // Review requested callout
        if let htmlUrl = pullRequest.html_url,
           let url = URL(string: htmlUrl),
           let reviewers = pullRequest.requested_reviewers,
           viewModel.hasMe(in: reviewers) {
          Link(destination: url) {
            Label("Review requested", systemImage: "exclamationmark.bubble")
              .font(.caption)
              .foregroundStyle(.yellow)
          }
        }
      }
    }
    .task {
      do {
        reviews = try await Github.loadReviews(
          organization: organization?.login ?? "",
          repository: repository.name,
          pullNumber: pullRequest.number
        )
      } catch {
        print("Error: \(error)")
      }
    }
  }
}

