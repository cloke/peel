import SwiftUI

public struct GitRootView: View {
  @ObservedObject public var repository: Model.Repository
  
  public init(repository: Model.Repository) {
    print("Switched to repository: \(repository.name)")
    self.repository = repository
    self.repository.load()
  }
  
  public var body: some View {
    VStack {
      List {
        LocalChangesListView()
        StashListView(repository: repository)
        BranchListView(branches: repository.branches.filter { $0.type == .local }, label: "Local Branches", location: .local)
        BranchListView(branches: repository.branches.filter { $0.type == .remote }, label: "Remote Branches", location: .remote)
      }
      Spacer()
    }
    .environmentObject(repository)
  }
}
