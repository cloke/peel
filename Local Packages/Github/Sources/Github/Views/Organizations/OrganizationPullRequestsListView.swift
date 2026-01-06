//
//  OrganizationPullRequestsListView.swift
//  OrganizationPullRequestsListView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI

struct OrganizationPullRequestsListView: View {
  @EnvironmentObject var viewModel: Github.ViewModel
  
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
            Link(destination: URL(string: pullRequest.html_url ?? "")!) {
              Image(systemName: "arrowshape.turn.up.right")
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
          if pullRequest.requested_reviewers != nil && pullRequest.requested_reviewers!.count > 0 {
            HStack {
              Text("Reviewers: \(pullRequest.requested_reviewers?.map { $0.publicName }.joined(separator: ", ") ?? "")")
              Spacer()
            }
          }
        }
#if os(macOS)
        Divider() // Weird bug, but compiler times out without something here
#else
        EmptyView()
#endif
      }
    }
  }
}


//struct OrganizationPullRequestsListView_Previews: PreviewProvider {
//    static var previews: some View {
//      OrganizationPullRequestsListView()
//    }
//}
