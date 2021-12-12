//
//  OrganizationRepositoryView.swift
//  OrganizationRepositoryView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI

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
  @EnvironmentObject var viewModel: Github.ViewModel
  
  let organization: Github.Organization
  
  @State private var members = [Github.User]()
  @State private var repositories = [Github.Repository]()
  @State private var pullRequests = [Github.PullRequest]()
  @State private var actions = [Github.Action]()
  @State private var runs = [Github.WorkflowRun]()
  
  var body: some View {
    VStack {
        AsyncImage(url: URL(string: organization.avatar_url)) { image in
          image
            .resizable()
            .scaledToFit()
            .clipped()
            .clipShape(Circle())
        } placeholder: {
          ProgressView()
        }
          .frame(minWidth: 0, maxWidth: 100, maxHeight: 100, alignment: .center)

      Text(organization.login)
      
      HStack {
        ForEach(members) { member in
          Spacer()
          AvatarView(url: URL(string: member.avatar_url), maxWidth: 100.0, maxHeight: 100)
//        URL(string: member.avatar_url)th: 100, maxHeight: 100, alignment: .center)
        }
        Spacer()
      }
            
      TabView(selection: /*@START_MENU_TOKEN@*//*@PLACEHOLDER=Selection@*/.constant(1)/*@END_MENU_TOKEN@*/) {
        OrganizationPullRequestsListView(pullRequests: pullRequests)
          .environmentObject(viewModel)
          .tabItem { Text("Pull Requests") }.tag(1)
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
        .tabItem { Text("Actions") }.tag(2)
        Link("Issues", destination: URL(string: organization.issues_url)!)
          .tabItem { Text("Issues") }.tag(3)
      }
      .onAppear {
        #if os(iOS)
        UITabBar.appearance().barTintColor = .white
        #endif
      }
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
