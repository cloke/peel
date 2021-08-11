//
//  Github.swift
//  Github
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import Kingfisher

extension Github {
  struct PersonalView: View {
    @EnvironmentObject var viewModel: Github.ViewModel
    @State private var pullRequests = [PullRequest]()

    let organizations: [Organization]

    var body: some View {
      List {
        ForEach(pullRequests.sorted(by: { $0.updated_at > $1.updated_at })) { pullRequest in
          VStack(alignment: .leading) {
            HStack {
              VStack {
                if let url = URL(string: pullRequest.base.repo.owner.avatar_url) {
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
                Text(pullRequest.base.repo.owner.login ?? "Unknown Owner")
                  .minimumScaleFactor(0.001)
                  .lineLimit(1)
                  .frame(width: 60)
              }
              VStack {
                HStack {
                  Text(pullRequest.title)
                  Spacer()
                  Text(pullRequest.dateFormated)
                }
                HStack {
                  if viewModel.hasMe(in: pullRequest.requested_reviewers),
                     let url = URL(string: pullRequest.html_url) {
                    HStack {
                      Link("Review Requested of Me", destination: url)
                        .foregroundColor(.yellow)
                    }
                  }
                  Text(pullRequest.base.repo.name)
                  Text(pullRequest.requested_reviewers.map({ $0.login ?? ""  }).joined(separator: ", "))
                  Spacer()
                  //          NavigationLink(destination: PullRequestDetailView(organization: pullRequest.base.repo.owner, repository: pullRequest.repository, pullRequest: pullRequest)) {
                  //            PullRequestsListItemView(pullRequest: pullRequest, organization: pullRequest.owner, repository: pullRequest.repository)
                  //          }
                }
                
              }
            }
            Divider()
          }
        }
      }
      .onAppear {
        for organization in organizations {
          Github.loadRepositories(organization: organization.login, success: { repositories in
            //              repositories = $0
            for repository in repositories {
              Github.pullRequests(from: repository) {
                pullRequests.append(contentsOf: $0)
              }
            }
          })
        }
      }
    }
  }
}

public struct Github {
  public struct RootView: View {
    @State private var organizations = [Organization]()
    @ObservedObject var viewModel = ViewModel()
    
    public init() {}
    
    public var body: some View {
      VStack {
        List {
          if hasToken && viewModel.me != nil {
            NavigationLink(destination: PersonalView(organizations: organizations)) {
              ProfileNameView(me: viewModel.me!)
            }
          } else {
            Button("Login") {
              Github.authorize(success:  {
                Github.me {
                  viewModel.me = $0
                }
                Github.loadOrganizations() {
                  organizations = $0
                }
              })
            }
          }
          ForEach(organizations) { organization in
            OrganizationRepositoryView(organization: organization)
          }
        }
        Spacer()
      }
      .onAppear {
        if hasToken {
          Github.authorize(success:  {
            Github.me {
              viewModel.me = $0
            }
            Github.loadOrganizations() {
              organizations = $0
            }
          })
        }
      }
      .environmentObject(viewModel)
    }
  }
}

struct ProfileNameView: View {
  let me: Github.User
  
  var body: some View {
    HStack {
      if #available(macOS 12.0, *) {
        AsyncImage(url: URL(string: me.avatar_url)) { image in
          image.resizable()
        } placeholder: {
          ProgressView()
        }
        .frame(width: 20, height: 20)
        .clipShape(Circle())
      }
      Text(me.name ?? "")
    }
  }
}
