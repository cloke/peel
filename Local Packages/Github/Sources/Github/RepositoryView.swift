//
//  RepositorView.swift
//  RepositorView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
extension Github {
  struct RepositorView: View {
    public let organization: String
    public let repository: String
    
    // TODO: make this reference an enum
    @State private var currentTab = "Pulls"
    
    var body: some View {
      VStack {
        HStack {
          Button("Pulls") { currentTab = "Pulls" }
          Button("Commits") { currentTab = "Commits" }
        }
        switch currentTab {
        case "Pulls":
          PullRequestsView(organization: organization, repository: repository)
        case "Commits":
          Text("Display commit logs here")
        default:
          Text("Something is wrong")
        }
      }
      Spacer()
    }
  }
}

//struct RepositoryView_Previews: PreviewProvider {
//  static var previews: some View {
//    Github.RepositorView(organization: "Test", repository: "Test")
//  }
//}
