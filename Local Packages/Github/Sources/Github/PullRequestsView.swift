//
//  PullRequestsView.swift
//  PullRequestsView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import Kingfisher
import CrunchyCommon

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
          Text(review.user.login ?? "Unknown Login")
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
      Github.loadReviews(organization: organization, repository: repository, pullNumber: pullNumber) {
        reviews = $0
      }
    }
  }
}

public struct PullRequestsView: View {
  public let organization: String
  public let repository: String
  
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var pullRequests = [Github.PullRequest]()
  @State private var isLoading = true
  
  public init(organization: String, repository: String) {
    self.organization = organization
    self.repository = repository
  }
  
  public var body: some View {
    List {
      if isLoading {
        ProgressView()
      } else {
        if pullRequests.count == 0 {
          Text("No Pull Requests Found")
        } else {
          ForEach(pullRequests) { pullRequest in
            VStack {
              VStack {
                HStack(alignment: .top) {
                  Text(pullRequest.state)
                  Text(pullRequest.title)
                  Spacer()
                }
                HStack {
                  ForEach(pullRequest.labels) { label in
                    Text(label.name)
                      .background(Color.init(hex: label.color))
                  }
                }
                
                if viewModel.hasMe(in: pullRequest.requested_reviewers),
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
                  Text("Reviewers: \(pullRequest.requested_reviewers.map { $0.publicName }.joined(separator: ", "))")
                  Spacer()
                }
                PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
              }
              Divider()
            }
          }
        }
      }
    }
    .onAppear {
      Github.loadPullRequests(organization: organization, repository: repository) {
        isLoading = false
        pullRequests = $0
      } error: {
        print($0)
      }
    }
  }
}
