//
//  OrganizationPullRequestsListView.swift
//  OrganizationPullRequestsListView
//
//  Created by Cory Loken on 8/6/21.
//  Modernized to @Observable on 1/5/26
//

import SwiftUI

struct OrganizationPullRequestsListView: View {
  @Environment(Github.ViewModel.self) private var viewModel
  
  var pullRequests: [Github.PullRequest]
  
  var body: some View {
    List {
      ForEach(pullRequests.sorted(by: { $0.updated_at ?? "" > $1.updated_at ?? ""})) { pullRequest in
        VStack {
          HStack {
            Text(pullRequest.head.repo.name)
            Text(pullRequest.user?.publicName ?? "")
            Text(pullRequest.title ?? "")
            Spacer()
            if let htmlUrl = pullRequest.html_url, let url = URL(string: htmlUrl) {
              Link(destination: url) {
                Image(systemName: "arrowshape.turn.up.right")
              }
            }
          }
          if let reviewers = pullRequest.requested_reviewers, viewModel.hasMe(in: reviewers) {
            if let htmlUrl = pullRequest.html_url,
               let url = URL(string: htmlUrl) {
              HStack {
                Link("Review Requested of Me", destination: url)
                  .foregroundColor(.yellow)
                Spacer()
              }
            }
          }
          if let reviewers = pullRequest.requested_reviewers, !reviewers.isEmpty {
            HStack {
              Text("Reviewers: \(reviewers.map { $0.publicName }.joined(separator: ", "))")
              Spacer()
            }
          }
        }
        Divider() // Weird bug, but compiler times out without something here
      }
    }
  }
}


//struct OrganizationPullRequestsListView_Previews: PreviewProvider {
//    static var previews: some View {
//      OrganizationPullRequestsListView()
//    }
//}
