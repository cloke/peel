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
  let organization: Github.Organization
  let repository: Github.Repository

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
      HStack(alignment: .top) {
        Text(prState)
        Spacer()
        Text(pullRequest.created_at)
      }
      .onAppear {
        Github.loadReviews(organization: organization.login, repository: repository.name, pullNumber: pullRequest.number) {
          reviews = $0
        }
      }
      
      Text(pullRequest.title)

      HStack {
        ForEach(pullRequest.labels) { label in
          let color = Color.init(hex: label.color)
          Text(label.name)
            .padding(3)
            .background(color)
            .cornerRadius(3)
            .foregroundColor(color.isDarkColor ? .white : .black)
        }
        Spacer()
      }
      
      if viewModel.hasMe(in: pullRequest.requested_reviewers),
         let url = URL(string: pullRequest.html_url) {
        HStack {
          Link("Review Requested of Me", destination: url)
            .foregroundColor(.yellow)
          Spacer()
        }
      }
      Spacer()
      if pullRequest.requested_reviewers.count > 0 {
        HStack {
          Text("Reviewers: \(pullRequest.requested_reviewers.map { $0.publicName }.joined(separator: ", "))")
          Spacer()
        }
//        PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
      }
    }
  }
}

