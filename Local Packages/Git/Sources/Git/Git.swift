import SwiftUI

#if os(macOS)
enum GitDestination: Hashable {
  case localChanges
  case history(String)
}

public struct GitRootView: View {
  @Bindable public var repository: Model.Repository
  @State private var selection: GitDestination?
  
  public init(repository: Model.Repository) {
    self.repository = repository
    Task {
      await repository.load()
    }
  }
  
  public var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section("Repository") {
          LocalChangesListView()
            .tag(GitDestination.localChanges)
          StashListView(repository: repository)
        }
        BranchListView(
          selection: $selection,
          localBranches: $repository.localBranches,
          label: "Local Branches",
          location: .local
        )
        BranchListView(
          selection: $selection,
          localBranches: $repository.remoteBranches,
          label: "Remote Branches",
          location: .remote
        )
        WorktreeListView()
      }
      .listStyle(.sidebar)
    } detail: {
      switch selection {
      case .localChanges:
        FileListView(repository: repository)
      case .history(let branchName):
        HistoryListView(branch: branchName)
      case .none:
        ContentUnavailableView {
          Label("Select an Item", systemImage: "arrow.left")
        } description: {
          Text("Choose a section from the sidebar to view details")
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle(repository.name)
    .environment(repository)
  }
}
#endif
