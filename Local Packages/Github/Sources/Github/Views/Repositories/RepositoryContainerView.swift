//
//  RepositoryView.swift
//  RepositoryView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI

public struct RepositoryContainerView: View {
  let organization: Github.User
  let repository: Github.Repository
  
  private enum Tab: Int {
    case insights, pullRequests, commits, issues, actions
  }
  
  @State private var selection = Tab.pullRequests
  
  public init(organization: Github.User, repository: Github.Repository) {
    self.organization = organization
    self.repository = repository
  }
  
  public var body: some View {
    NavigationStack {
      TabView(selection: $selection) {
        RepositoryInsightsView(repository: repository)
          .tabItem { Text("Insights") }
          .tag(Tab.insights)
        PullRequestsView(organization: organization, repository: repository)
          .tabItem { Text("Pull Requests") }
          .tag(Tab.pullRequests)
        CommitsListView(repository: repository)
          .tabItem { Text("Commits") }
          .tag(Tab.commits)
        IssuesListView(repository: repository)
          .tabItem { Text("Issues") }
          .tag(Tab.issues)
        ActionsView(repository: repository)
          .tabItem { Text("Actions") }
          .tag(Tab.actions)
      }
      .navigationTitle(repository.full_name ?? repository.name)
    }
  }
}

//struct RepositoryView_Previews: PreviewProvider {
//  static var previews: some View {
//    Github.RepositorView(organization: "Test", repository: "Test")
//  }
//}
