//
//  OrganizationRepositoryView.swift
//  OrganizationRepositoryView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI
import Kingfisher

struct ActionConclusionView: View {
  let conclusion: String
  
  var body: some View {
    Group {
      switch conclusion {
      case "success":
        Image(systemName: "checkmark.circle")
          .foregroundColor(.green)
      case "failure":
        Image(systemName: "xmark.circle")
          .foregroundColor(.red)
      case "cancelled":
        Image(systemName: "nosign")
          .foregroundColor(.yellow)
      default:
        Image(systemName: "questionmark.circle")
      }
    }
    .help(conclusion)
  }
}

struct OrganizationDetailView: View {
  let organization: Github.Organization
  
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var members = [Github.User]()
  @State private var repositories = [Github.Repository]()
  @State private var pullRequests = [Github.PullRequest]()
  @State private var actions = [Github.Action]()
  @State private var runs = [Github.WorkflowRun]()
  
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
        ForEach(actions.sorted(by: { $0.updated_at > $1.updated_at })) { action in
          VStack {
            HStack {
              if action.status == "in_progress" {
                ProgressView()
                  .scaleEffect(0.5)
              } else {
                ActionConclusionView(conclusion: action.conclusion ?? "")
              }
              Text("#\(action.run_number)")
              Text(action.head_commit.message.components(separatedBy: "\n\n").first ?? "")
              Spacer()
              Text(action.updatedAtFormatted)
            }
            HStack {
              Text(action.repository.name)
              Text(action.name)
              Spacer()
            }
          }
        }
      }
      
      OrganizationPullRequestsListView(pullRequests: pullRequests)
    }
    .onAppear {
      Github.members(from: organization) {
        members = $0
      }
      
      Github.loadRepositories(organization: organization.login, success: {
        repositories = $0
        for repository in repositories {
          Github.pullRequests(from: repository) {
            pullRequests.append(contentsOf: $0)
          }
          
          Github.workflows(from: repository, success: { workflows in
            for workflow in workflows {
              Github.runs(from: workflow, repository: repository, success: { actions in
                self.actions.append(contentsOf: actions)
              })
            }
          })
        }
      })
    }
  }
}
