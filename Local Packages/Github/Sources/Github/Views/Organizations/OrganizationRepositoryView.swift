//
//  OrganizationRepositoryView.swift
//  Lazy-loading organization repository list
//
//  Created by Cory Loken on 7/19/21.
//

import PeelUI
import SwiftUI

public struct OrganizationRepositoryView: View {
  @State private var state: ViewState<[Github.Repository]> = .idle
  @State private var isExpanded = false
  @AppStorage("github-show-archived") private var showArchivedRepos = false
  
  let organization: Github.User

  public init(organization: Github.User) {
    self.organization = organization
  }
  
  public var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      switch state {
      case .idle:
        EmptyView()
      case .loading:
        ProgressView()
      case .error(let message):
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .font(.caption)
      case .loaded(let repositories):
        ForEach(repositories) { repository in
          NavigationLink(destination: RepositoryContainerView(organization: organization, repository: repository)) {
            Text(repository.name)
          }
        }
      }
    } label: {
      Text(organization.login ?? "")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { isExpanded.toggle() } }
    }
    .onChange(of: isExpanded) { _, expanded in
      guard expanded, case .idle = state else { return }
      Task { await loadRepositories() }
    }
  }
  
  private func loadRepositories() async {
    state = .loading
    do {
      let repos = try await Github.loadRepositories(organization: organization.login ?? "")
      let filtered = showArchivedRepos ? repos : repos.filter { $0.archived != true }
      state = .loaded(filtered)
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}
