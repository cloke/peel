//
//  Github_RootView.swift
//  KitchenSink (macOS)
//
//  Created by Cory Loken on 7/14/21.
//

import SwiftUI
import Github

struct RepositoriesView: View {
  let organization: String
  var repositories = [Github.Repository]()
  
  var body: some View {
    ForEach(repositories) { repository in
      NavigationLink(destination: Github.PullRequestsView(organization: organization, repository: repository.name)) {
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
    VStack {
      Github.RootView()
        .frame(minWidth: 100)
    }
    .frame(idealHeight: 400)
    .toolbar {
      ToolSelectionToolbar()
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
