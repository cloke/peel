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
  @State private var showArchived = false
  
  let organization: Github.User

  public init(organization: Github.User) {
    self.organization = organization
  }
  
  /// Filtered repositories based on archived toggle
  private var filteredRepositories: [Github.Repository] {
    if showArchived {
      return repositories
    }
    return repositories.filter { $0.archived != true }
  }
  
  /// Count of archived repos for display
  private var archivedCount: Int {
    repositories.filter { $0.archived == true }.count
  }
  
  public var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      if isLoading {
        ProgressView()
      } else {
        // Show archived toggle if there are archived repos
        if archivedCount > 0 {
          Toggle(isOn: $showArchived) {
            Text("Show archived (\(archivedCount))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .toggleStyle(.checkbox)
          .padding(.leading, 4)
        }
        
        ForEach(filteredRepositories) { repository in
          NavigationLink(
            destination: RepositoryContainerView(organization: organization, repository: repository),
            label: {
              HStack {
                Text(repository.name)
                if repository.archived == true {
                  Text("archived")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
                }
                Spacer()
                FavoriteButton(repository: repository)
              }
            }
          )
        }
      }
    } label: {
      HStack {
        Text(organization.login ?? "")
        if !isLoading && !repositories.isEmpty {
          Text("\(filteredRepositories.count)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .onChange(of: isExpanded) { _, newValue in
      if newValue && repositories.isEmpty {
        Task {
          repositories = try await Github.loadRepositories(organization: organization.login ?? "")
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
