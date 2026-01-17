//
//  OrganizationRepositoryView.swift
//  OrganizationRepositoryView
//
//  Created by Cory Loken on 7/19/21.
//

import SwiftUI

public struct OrganizationRepositoryView: View {
  @State var isLoading = true
  @State var isExpanded = false
  @State private var repositories = [Github.Repository]()
  @AppStorage("github-show-archived") private var showArchivedRepos = false
  
  let organization: Github.User

  public init(organization: Github.User) {
    self.organization = organization
  }
  
  public var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      if isLoading {
        ProgressView()
      }
      ForEach(repositories) { repository in
        NavigationLink(
          destination: RepositoryContainerView(organization: organization, repository: repository),
          label: { Text(repository.name) }
        )
      }
    } label: {
      Text(organization.login ?? "")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
          withAnimation {
            isExpanded.toggle()
          }
        }
    }
    .onChange(of: isExpanded) { _, newValue in
      if newValue {
        Task {
          let repos = try await Github.loadRepositories(organization: organization.login ?? "")
          repositories = showArchivedRepos ? repos : repos.filter { $0.archived != true }
          isLoading = false
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
