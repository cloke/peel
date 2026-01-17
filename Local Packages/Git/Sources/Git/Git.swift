import SwiftUI

#if os(macOS)
public struct GitRootView: View {
  @Bindable public var repository: Model.Repository
  
  public init(repository: Model.Repository) {
    self.repository = repository
    Task {
      await repository.load()
    }
  }
  
  public var body: some View {
    NavigationSplitView {
      List {
        Section("Repository") {
          LocalChangesListView()
          StashListView(repository: repository)
        }
        BranchListView(localBranches: $repository.localBranches, label: "Local Branches", location: .local)
        BranchListView(localBranches: $repository.remoteBranches, label: "Remote Branches", location: .remote)
        WorktreeListView()
      }
      .listStyle(.sidebar)
    } detail: {
      ContentUnavailableView {
        Label("Select an Item", systemImage: "arrow.left")
      } description: {
        Text("Choose a section from the sidebar to view details")
      }
    }
    .navigationDestination(for: String.self) { branchName in
      HistoryListView(branch: branchName)
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle(repository.name)
    .environment(repository)
  }
}
#endif
