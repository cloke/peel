//
//  Github_RootView.swift
//  KitchenSync (macOS)
//
//  Created by Cory Loken on 7/14/21.
//

import SwiftUI
import Github

struct RepositoriesView: View {
  let organization: Github.Organization
  var repositories = [Github.Repository]()
  
  var body: some View {
    ForEach(repositories) { repository in
      NavigationLink(destination: PullRequestsView(organization: organization, repository: repository)) {
        Text(repository.name)
      }
    }
  }
}

struct VerticalLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack {
      configuration.icon.font(.headline)
      configuration.title.font(.subheadline)
    }
  }
}

struct Github_RootView: View {
  var body: some View {
    Github.RootView()
      .frame(minWidth: 100)
      .frame(idealHeight: 400)
      .toolbar {
#if os(macOS)
        ToolSelectionToolbar()
#endif
        ToolbarItem(placement: .navigation) {
          Menu {
            Button {
              Github.reauthorize()
            } label: {
              Text("Logout")
              Image(systemName: "figure.wave")
            }
          } label: {
            Image(systemName: "gear")
          }
        }
      }
  }
}

struct Github_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Github_RootView()
  }
}
