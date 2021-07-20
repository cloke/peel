//
//  OrganizationRepositoryView.swift
//  OrganizationRepositoryView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import Kingfisher

struct OrganizationDetailView: View {
  let organization: Github.Organization
  
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var members = [Github.User]()
  @State private var repositories = [Github.Repository]()
  @State private var pullRequests = [Github.PullRequest]()
  
  var body: some View {
    VStack {
      if let url = URL(string: organization.avatar_url) {
        KFImage.url(url)
          .cancelOnDisappear(true)
        //            .onFailure { error in
        //              collapse = true
        //            }
          .fade(duration: 0.25)
          .resizable()
          .scaledToFit()
          .frame(minWidth: 0, maxWidth: 100, maxHeight: 100, alignment: .center)
          .clipped()
          .clipShape(Circle())
      }
      Text(organization.login)
      
      HStack {
        ForEach(members) { member in
          if let url = URL(string: member.avatar_url) {
            Spacer()
            KFImage.url(url)
              .cancelOnDisappear(true)
            //            .onFailure { error in
            //              collapse = true
            //            }
              .fade(duration: 0.25)
              .resizable()
              .scaledToFit()
              .frame(minWidth: 0, maxWidth: 100, maxHeight: 100, alignment: .center)
              .clipped()
              .clipShape(Circle())
          }
        }
        Spacer()
      }
      
      Link("Issues", destination: URL(string: organization.issues_url)!)
      List {
        ForEach(pullRequests) { pullRequest in
          VStack {
            HStack {
              Text(pullRequest.head.repo.name)
              Text(pullRequest.user.publicName)
              Text(pullRequest.title)
              Spacer()
              Link(destination: URL(string: pullRequest.html_url)!) {
                Image(systemName: "arrowshape.turn.up.right")
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
            if pullRequest.requested_reviewers.count > 0 {
              HStack {
                Text("Reviewers: \(pullRequest.requested_reviewers.map { $0.publicName }.joined(separator: ", "))")
                Spacer()
              }
            }
          }
          Divider()
        }
      }
    }
    .onAppear {
      Github.members(from: organization) {
        members = $0
      }
      Github.loadRepositories(organization: organization.login, success: {
        repositories = $0
        for repository in repositories {
          Github.loadPullRequests(organization: organization.login, repository: repository.name) {
            pullRequests.append(contentsOf: $0)
          }
        }
      })
    }
  }
}
