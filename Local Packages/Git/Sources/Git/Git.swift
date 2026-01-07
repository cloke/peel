import SwiftUI

#if os(macOS)
public struct GitRootView: View {
  @ObservedObject public var repository: Model.Repository
  
  public init(repository: Model.Repository) {
    print("Switched to repository: \(repository.name)")
    self.repository = repository
    Task {
      await repository.load()
    }
  }
  
  public var body: some View {
    NavigationView {
      VStack {
        List {
          LocalChangesListView()
          StashListView(repository: repository)
          BranchListView(localBranches: $repository.localBranches, label: "Local Branches", location: .local)
          BranchListView(localBranches: $repository.remoteBranches, label: "Remote Branches", location: .remote)
        }
        .listStyle(.sidebar)
        .navigationDestination(for: String.self) { branchName in
          HistoryListView(branch: branchName)
        }
      }
      .environmentObject(repository)
      Text("Hello")
    }
  }
}
#endif
