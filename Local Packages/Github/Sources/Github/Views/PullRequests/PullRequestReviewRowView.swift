//
//  PullRequestReviewRowView.swift
//  PullRequestReviewRowView
//
//  Created by Cory Loken on 7/20/21.
//

import SwiftUI
import Kingfisher

struct PullRequestReviewRowView: View {
  let organization: Github.Organization
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
          if let url = URL(string: review.user.avatar_url) {
            KFImage.url(url)
              .cancelOnDisappear(true)
            //            .onFailure { error in
            //              collapse = true
            //            }
              .fade(duration: 0.25)
              .resizable()
              .scaledToFit()
              .frame(minWidth: 0, maxWidth: 30, maxHeight: 30, alignment: .center)
              .clipped()
              .clipShape(Circle())
            
          } else {
            EmptyView()
          }
        }
      }
    }
    .onAppear {
      Github.loadReviews(organization: organization.login, repository: repository.name, pullNumber: pullNumber) {
        reviews = $0
      }
    }
  }
}
