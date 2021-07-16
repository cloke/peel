//
//  PullRequestsView.swift
//  PullRequestsView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import Kingfisher

extension Github {
  struct PullRequestReviewRowView: View {
    let organization: String
    let repository: String
    let pullNumber: Int
    
    @State private var reviews = [Github.Review]()
    
    var body: some View {
      VStack {
        ForEach(reviews) { review in
          HStack {
            Spacer()
            Text(review.user.login)
            Text(review.state)
              .background(review.state == "APPROVED" ? Color.green : Color.clear)
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
        loadReviews(organization: organization, repository: repository, pullNumber: pullNumber) {
          reviews = $0
        }
      }
    }
  }
  
  public struct PullRequestsView: View {
    public let organization: String
    public let repository: String
    
    @EnvironmentObject var githubViewModel: ViewModel
    @State private var pullRequests = [Github.PullRequest]()
    
    public init(organization: String, repository: String) {
      self.organization = organization
      self.repository = repository
    }
    
    func isMe(reviewers: [User]) -> Bool {
      guard let me = githubViewModel.me?.login,
            let _ = reviewers.first(where: { $0.login == me })
      else { return false }
      return true
    }
    
    public var body: some View {
      List(pullRequests) { pullRequest in
        VStack {
          VStack {
            HStack(alignment: .top) {
              Text(pullRequest.state)
              Text(pullRequest.title)
              Spacer()
            }
            if isMe(reviewers: pullRequest.requested_reviewers),
               let url = URL(string: pullRequest.html_url) {
              HStack {
                Link("Review Requested of Me", destination: url)
                  .foregroundColor(.yellow)
                Spacer()
              }
            }
          }
          Spacer()
          if pullRequest.requested_reviewers.count > 0 {
            HStack {
              Text("Reviewers: \(pullRequest.requested_reviewers.map {$0.login }.joined(separator: ", "))")
              Spacer()
            }
            PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
          }
          Divider()
        }
      }
      .onAppear {
        loadPullRequests(organization: organization, repository: repository) {
          pullRequests = $0
        } error: {
          print($0)
        }
      }
    }
  }
}
