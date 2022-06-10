//
//  PullRequestsView.swift
//  PullRequestsView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import CrunchyCommon
import MarkdownUI

struct PullRequestDetailView: View {
  let organization: Github.User?
  let repository: Github.Repository
  let pullRequest: Github.PullRequest
  
  var body: some View {
    VStack(alignment: .leading) {
      Text(pullRequest.title ?? "")
        .font(.title)
      Divider()
      Text("Description")
        .font(.headline)
      ScrollView {
        Markdown(Document(stringLiteral: pullRequest.body ?? ""))
      }
      PullRequestReviewRowView(organization: organization, repository: repository, pullNumber: pullRequest.number)
      Spacer()
    }
    .padding()
  }
}

struct PullRequestListView: View {
  let organization: Github.User
  let repository: Github.Repository
  let pullRequests: [Github.PullRequest]
  
  var body: some View {
#if os(macOS)
    NavigationView {
      List {
        ForEach(pullRequests) { pullRequest in
          NavigationLink(destination: PullRequestDetailView(organization: organization, repository: repository, pullRequest: pullRequest)) {
            PullRequestsListItemView(pullRequest: pullRequest, organization: organization, repository: repository)
          }
          Divider()
        }
      }
    }
#else
    List {
      ForEach(pullRequests) { pullRequest in
        NavigationLink(destination: PullRequestDetailView(organization: organization, repository: repository, pullRequest: pullRequest)) {
          PullRequestsListItemView(pullRequest: pullRequest, organization: organization, repository: repository)
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
#endif
  }
}

public struct PullRequestsView: View {
  public let organization: Github.User
  public let repository: Github.Repository
  
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var pullRequests = [Github.PullRequest]()
  @State private var state: LoadingState = .loading
  
  public init(organization: Github.User, repository: Github.Repository) {
    self.organization = organization
    self.repository = repository
  }
  
  public var body: some View {
    VStack {
      switch state {
      case .loading:
        ProgressView()
      case .loaded:
        PullRequestListView(organization: organization, repository: repository, pullRequests: pullRequests)
      case .empty:
        Text("No Pull Requests Found")
      }
    }
    .onAppear {
      Github.pullRequests(from: repository) {
        pullRequests = $0
        state = $0.count == 0 ? .empty : .loaded
      } error: {
        print($0)
      }
    }
  }
}
