//
//  PullRequestsListItemView.swift
//  PullRequestsListItemView
//
//  Created by Cory Loken on 7/20/21.
//

import SwiftUI

struct PullRequestsListItemView: View {
  @EnvironmentObject var viewModel: Github.ViewModel
  let pullRequest: Github.PullRequest
  let organization: Github.User?
  let repository: Github.Repository
  var showAvatar = false
  var showRepository = false

  @State private var reviews = [Github.Review]()
  
  var prState: String {
    if reviews.count > 0 {
      var state = "Discussing"
      reviews.forEach {
        // TODO: If there is an approval and a rejection basically last one wins for now. Eventually rejection should be priority.
        if $0.state == "APPROVED" {  state = "Approved" }
        if $0.state == "CHANGES_REQUESTED" {  state = "Changes Requested" }
      }
      
      return state
    }
    
    // TODO: id now requested reviewers we can poll for comments (issues/:id/comments) to see if there is discussion
    if let comments = pullRequest.comments, comments > 0 {
      return "Discussing"
    }
    return "Open"
  }
  
  var body: some View {
    VStack {
      if showAvatar || showRepository {
        HStack {
          if showAvatar {
            AvatarView(url: URL(string: organization?.avatar_url ?? ""), maxHeight: 20)
          }
          if showRepository {
            Text(repository.name)
              .padding(3)
              .cornerRadius(3)
          }
          Spacer()
        }
      }
      HStack(alignment: .top) {
        Text(prState)
          .font(.headline)
        Spacer()
        Text(pullRequest.dateFormated)
          .font(.subheadline)
      }
      .onAppear {
        Github.loadReviews(organization: organization?.login ?? "", repository: repository.name, pullNumber: pullRequest.number) {
          reviews = $0
        }
      }
      
      Text(pullRequest.title ?? "")
        .font(.body)

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
      Spacer()
      if  pullRequest.requested_reviewers != nil && pullRequest.requested_reviewers!.count > 0 {
        HStack {
          Text("Reviewers: \(pullRequest.requested_reviewers?.map { $0.publicName }.joined(separator: ", ") ?? "")")
          Spacer()
        }
      }
    }
  }
}

