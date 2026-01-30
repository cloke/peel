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
  
  
  var body: some View {
    VStack {
      AvatarAndRepositoryView()
      HStack(alignment: .top) {
        Text(prState)
          .font(.headline)
        Spacer()
        Text(pullRequest.dateFormatted)
          .font(.subheadline)
      }
      .task {
        do {
          reviews = try await Github.loadReviews(organization: organization?.login ?? "", repository: repository.name, pullNumber: pullRequest.number)
        } catch {
          // Handle the error
          print("Error: \(error)")
        }
      }
      TitleAndLabelsView()
      ReviewerViews()
    }
  }
  
  @ViewBuilder
  private func AvatarAndRepositoryView() -> some View {
    if showAvatar || showRepository {
      HStack {
        if showAvatar {
          AvatarView(url: URL(string: organization?.avatar_url ?? ""), maxHeight: 20)
        }
        Spacer()
        if showRepository {
          Text(repository.name)
            .padding(3)
            .cornerRadius(3)
        }
      }
    }
  }
  
  @ViewBuilder
  private func TitleAndLabelsView() -> some View {
    Text(pullRequest.title ?? "")
      .font(.body)
      .frame(maxWidth: .infinity, alignment: .leading)

    HStack {
      ForEach(pullRequest.labels ?? []) { label in
        let color = Color.init(hex: label.color)
        Text(label.name)
          .padding(3)
          .background(color)
          .cornerRadius(3)
          .foregroundColor(color.isDarkColor ? .white : .black)
      }
      Spacer()
    }
  }
  
  @ViewBuilder
  private func ReviewerViews() -> some View {
    if let htmlUrl = pullRequest.html_url,
       let url = URL(string: htmlUrl),
       let reviewers = pullRequest.requested_reviewers,
        viewModel.hasMe(in: reviewers) {
      HStack {
        Link("Review Requested of Me", destination: url)
          .foregroundColor(.yellow)
        Spacer()
      }
    }
    if pullRequest.requested_reviewers != nil && pullRequest.requested_reviewers!.count > 0 {
      HStack {
          ForEach(pullRequest.requested_reviewers!) {
            AvatarView(url: URL(string: $0.avatar_url), maxWidth: 15, maxHeight: 15)
          }
        
        Spacer()
      }
    }
  }
}

