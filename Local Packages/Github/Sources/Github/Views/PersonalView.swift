//
//  PersonalView.swift
//  
//
//  Created by Cory Loken on 12/12/21.
//

import SwiftUI

public struct PersonalHeaderView: View {
  @EnvironmentObject var viewModel: Github.ViewModel
  @Binding var pullRequests: [Github.PullRequest]
  @State private var pullRequestCache = [Github.PullRequest]()
  
  public var body: some View {
    HStack {
      Spacer()
      Button("My Requests") {
        withAnimation {
          pullRequestCache = pullRequests
          pullRequests = pullRequests.filter { viewModel.hasMe(in: $0.requested_reviewers ?? []) }
        }
      }
      Button("All") {
        withAnimation {
          pullRequests = pullRequestCache
        }
      }
    }
  }
}

public struct PersonalView: View {
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var pullRequests = [Github.PullRequest]()
  
  let organizations: [Github.User]
  
  public init(organizations: [Github.User]) {
    self.organizations = organizations
  }
  
  public var body: some View {
    VStack {
      PersonalHeaderView(pullRequests: $pullRequests)
        .padding(.horizontal)
      List {
        ForEach(pullRequests.sorted(by: { $0.updated_at ?? "" > $1.updated_at ?? ""})) { pullRequest in
          VStack {
            NavigationLink(destination: PullRequestDetailView(organization: pullRequest.base.repo.owner, repository: pullRequest.base.repo, pullRequest: pullRequest)) {
              PullRequestsListItemView(pullRequest: pullRequest, organization: pullRequest.base.repo.owner, repository: pullRequest.base.repo, showAvatar: true, showRepository: true)
            }
#if os(macOS)
            Divider()
#endif
          }
        }
      }
      .frame(idealWidth: 300)
      .onAppear {
        for organization in organizations {
          Task {
            do {
              let repositories = try await Github.loadRepositories(organization: organization.login ?? "")
              for repository in repositories {
                let requests = try await Github.pullRequests(from: repository)
                pullRequests.append(contentsOf: requests)
              }
            }
          }
        }
      }
    }
  }
}

//struct PersonalView_Previews: PreviewProvider {
//  static var previews: some View {
//    PersonalView()
//  }
//}
