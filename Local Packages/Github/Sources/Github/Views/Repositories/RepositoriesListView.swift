//
//  RepositoriesListView.swift
//  
//
//  Created by Cory Loken on 6/12/22.
//

import SwiftUI

struct RepositoriesListView: View {
  let organization: Github.User
  var repositories = [Github.Repository]()
  
  var body: some View {
    ForEach(repositories) { repository in
      NavigationLink(destination: PullRequestsView(organization: organization, repository: repository)) {
        HStack {
          Text(repository.name)
          Spacer()
          FavoriteButton(repository: repository)
        }
      }
    }
  }
}
