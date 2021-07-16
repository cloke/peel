//
//  OrganizationRepositoryView.swift
//  OrganizationRepositoryView
//
//  Created by Cory Loken on 7/15/21.
//

import SwiftUI

extension Github {
  struct OrganizationRepositoryView: View {
    let organization: Organization
    @State var isExpanded = false
    @State private var repositories = [Repository]()
    
    var body: some View {
      DisclosureGroup(isExpanded: $isExpanded) {
        ForEach(repositories) { repository in
          NavigationLink(destination: Github.PullRequestsView(organization: organization.login, repository: repository.name)) {
            Text(repository.name)
          }
        }
      } label: {
        HStack {
          Text(organization.login)
        }
        .onAppear {
          Github.loadRepositories(organization: organization.login) {
            repositories = $0
          }
        }
      }
    }
  }
}
