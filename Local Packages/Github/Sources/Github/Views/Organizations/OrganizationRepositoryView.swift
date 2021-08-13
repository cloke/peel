//
//  OrganizationRepositoryView.swift
//  OrganizationRepositoryView
//
//  Created by Cory Loken on 7/19/21.
//

import SwiftUI

struct OrganizationRepositoryView: View {
  @EnvironmentObject var viewModel: Github.ViewModel
  
  let organization: Github.Organization
  
  @State var isExpanded = false
  @State private var repositories = [Github.Repository]()
  
  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(repositories) { repository in
        NavigationLink(
          destination: RepositoryView(organization: organization, repository: repository)
            .environmentObject(viewModel),
          label: { Text(repository.name) }
        )
      }
    } label: {
      HStack {
        NavigationLink(
          destination: OrganizationDetailView(organization: organization)
            .environmentObject(viewModel),
          label: { Text(organization.login) }
        )
      }
      .onAppear {
        Github.loadRepositories(organization: organization.login) {
          repositories = $0
        }
      }
    }
  }
}

//struct OrganizationRepositoryView_Previews: PreviewProvider {
//  static var previews: some View {
//    OrganizationRepositoryView(organization: Github.Organization())
//  }
//}
