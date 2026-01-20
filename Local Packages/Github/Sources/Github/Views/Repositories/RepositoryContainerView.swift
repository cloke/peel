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
  
  // TODO: make this reference an enum
  @State private var currentTab = "Pulls"
  @State private var selection = 1
  
  public init(organization: Github.User, repository: Github.Repository) {
    self.organization = organization
    self.repository = repository
  }
  
  public var body: some View {
    NavigationStack {
      TabView(selection: $selection) {
        RepositoryInsightsView(repository: repository)
          .tabItem { Text("Insights") }
          .tag(0)
        PullRequestsView(organization: organization, repository: repository)
          .tabItem { Text("Pull Requests") }
          .tag(1)
        CommitsListView(repository: repository)
          .tabItem { Text("Commits") }
          .tag(2)
        IssuesListView(repository: repository)
          .tabItem { Text("Issues") }
          .tag(3)
        ActionsView(repository: repository)
          .tabItem { Text("Actions") }
          .tag(4)
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
