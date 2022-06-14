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
          BranchListView(branches: repository.branches.filter { $0.type == .local }, label: "Local Branches", location: .local)
          BranchListView(branches: repository.branches.filter { $0.type == .remote }, label: "Remote Branches", location: .remote)
        }
        .listStyle(.sidebar)
      }
      .environmentObject(repository)
      Text("Hello")
    }
  }
}
#endif
