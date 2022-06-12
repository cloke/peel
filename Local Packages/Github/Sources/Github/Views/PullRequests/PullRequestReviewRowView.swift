//
//  PullRequestReviewRowView.swift
//  PullRequestReviewRowView
//
//  Created by Cory Loken on 7/20/21.
//

import SwiftUI

struct PullRequestReviewRowView: View {
  let organization: Github.User?
  let repository: Github.Repository
  let pullNumber: Int
  
  @State private var reviews = [Github.Review]()
  
  var body: some View {
    VStack {
      ForEach(reviews) { review in
        HStack {
          Spacer()
          Text(review.user.login ?? "Unknown Login")
          Text(review.state)
            .padding(3)
            .background(review.state == "APPROVED" ? Color.green : Color.clear)
            .cornerRadius(3)
          AvatarView(url: URL(string: review.user.avatar_url))
        }
      }
    }
    .task {
      do {
        reviews = try await Github.loadReviews(organization: organization?.login ?? "", repository: repository.name, pullNumber: pullNumber)
      } catch {
        
      }
    }
  }
}
