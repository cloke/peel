//
//  RepositoryView.swift
//  RepositoryView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
// Used for hex color
import CrunchyCommon

struct RepositoryContainerView: View {
  public let organization: Github.User
  public let repository: Github.Repository
  
  // TODO: make this reference an enum
  @State private var currentTab = "Pulls"
  @State private var selection = 1
  
  var body: some View {
    TabView(selection: $selection) {
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
  }
}

//struct RepositoryView_Previews: PreviewProvider {
//  static var previews: some View {
//    Github.RepositorView(organization: "Test", repository: "Test")
//  }
//}
