//
//  RepositoryView.swift
//  RepositoryView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
// Used for hex color
import CrunchyCommon

struct RepositoryView: View {
  public let organization: Github.Organization
  public let repository: Github.Repository
  
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
        Button {
          currentTab = "Issues"
        } label: {
          Text("Issues")
            .fontWeight(currentTab == "Issues" ? .bold : .none)
        }
        Button {
          currentTab = "Actions"
        } label: {
          Text("Actions")
            .fontWeight(currentTab == "Actions" ? .bold : .none)
        }
        
      }
      //        .buttonStyle(.borderless)
      switch currentTab {
      case "Pulls":
        PullRequestsView(organization: organization, repository: repository)
      case "Commits":
        CommitsListView(repository: repository)
      case "Issues":
        IssuesLisView(repository: repository)
      case "Actions":
        ActionsListView(repository: repository)

      default:
        Text("Something is wrong")
      }
    }
    Spacer()
  }
}

struct ActionsListView: View {
  public let repository: Github.Repository
  
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var actions = [Github.Action]()
  
  var body: some View {
    NavigationView {
      List(actions) { action in
        VStack {
//          NavigationLink(destination: CommitDetailView(commit: commit)) {
//            CommitsListItemView(commit: commit)
//          }
          Text(action.name)
          Divider()
        }
      }
    }
    .onAppear {
      Github.actions(from: repository) {
        actions = $0.workflow_runs
      } error: {
        print($0)
      }
    }
  }
}

//struct RepositoryView_Previews: PreviewProvider {
//  static var previews: some View {
//    Github.RepositorView(organization: "Test", repository: "Test")
//  }
//}
