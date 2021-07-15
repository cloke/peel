//
//  Github_RootView.swift
//  KitchenSink (macOS)
//
//  Created by Cory Loken on 7/14/21.
//

import SwiftUI
import Alamofire
import Github
import Kingfisher

class GithubViewModel: ObservableObject {
  @Published var me: Github.User?
}

struct Github_RootView: View {
  @State private var organizations = [Github.Organization]()
  @ObservedObject var githubViewModel = GithubViewModel()
  
  var body: some View {
    VStack {
      Text(githubViewModel.me?.name ?? "Nothing")
      Button("Test Login") {
        Github.authorize(success:  {
          Github.me {
            githubViewModel.me = $0
          }
          Github.loadOrganizations() {
            organizations = $0
          }
        })
      }
      List(organizations) { organization in
        NavigationLink(
          destination: RepositoriesView(organization: organization.login),
          label: {
            Text(organization.login)
          })
      }
      .environmentObject(githubViewModel)
      .toolbar {
        ToolSelectionToolbar()
      }
    }
  }
}

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
      Github.loadReviews(organization: organization, repository: repository, pullNumber: pullNumber) {
        reviews = $0
      }
    }
  }
}

struct PullRequestsView: View {
  let organization: String
  let repository: String
  
  @State private var pullRequests = [Github.PullRequest]()
  @EnvironmentObject var githubViewModel: GithubViewModel
  
  func isMe(reviewers: [Github.User]) -> Bool {
    guard let me = githubViewModel.me?.login,
          let _ = reviewers.first(where: { $0.login == me })
    else { return false }
    return true
  }
  
  var body: some View {
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
      Github.loadPullRequests(organization: organization, repository: repository) {
        pullRequests = $0
      } error: {
        print($0)
      }
    }
  }
}

struct RepositoriesView: View {
  let organization: String
  @State private var repositories = [Github.Repository]()
  
  var body: some View {
    NavigationView {
      List(repositories) { repository in
        NavigationLink(destination: PullRequestsView(organization: organization, repository: repository.name)) {
          Text(repository.name)
        }
      }
    }
    .onAppear {
      Github.loadRepositories(organization: organization) {
        repositories = $0
      }
    }
  }
}

struct Github_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Github_RootView()
  }
}
