//
//  RepositoryView.swift
//  RepositoryView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
extension Github {
  struct RepositoryView: View {
    public let organization: String
    public let repository: Repository
    
    // TODO: make this reference an enum
    @State private var currentTab = "Pulls"
    
    var body: some View {
      VStack {
        HStack {
          Button {
            currentTab = "Pulls"
          } label:  {
            Text("Pulls")
              .fontWeight(currentTab == "Pulls" ? .bold : .none)
          }
          
          Button {
            currentTab = "Commits"
          } label: {
            Text("Commits")
              .fontWeight(currentTab == "Commits" ? .bold : .none)
          }
        }
        .buttonStyle(.borderless)
        switch currentTab {
        case "Pulls":
          PullRequestsView(organization: organization, repository: repository.name)
        case "Commits":
          CommitsListView(organization: organization, repository: repository)
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
