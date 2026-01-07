import SwiftUI

#if os(macOS)
public struct GitRootView: View {
  @Bindable public var repository: Model.Repository
  
  public init(repository: Model.Repository) {
    print("Switched to repository: \(repository.name)")
    self.repository = repository
    Task {
      await repository.load()
    }
  }
  
  public var body: some View {
    let _ = print("🟣 GitRootView rendering body for repo: \(repository.name)")
    NavigationStack {
      List {
        LocalChangesListView()
        StashListView(repository: repository)
        BranchListView(localBranches: $repository.localBranches, label: "Local Branches", location: .local)
        BranchListView(localBranches: $repository.remoteBranches, label: "Remote Branches", location: .remote)
      }
      .listStyle(.sidebar)
      .navigationTitle(repository.name)
      .environment(repository)
    }
  }
}
#endif
