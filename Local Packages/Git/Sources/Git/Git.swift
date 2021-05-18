import SwiftUI

public struct GitRootView: View {
  let repository: Model.Repository
  
  public init(repository: Model.Repository) {
    self.repository = repository
  }
  
  public var body: some View {
    VStack {
      List {
        LocalChangesListView(repository: repository)
        StashListView(repository: repository)
        BranchListView(label: "Local Branches", location: "-l")
        BranchListView(label: "Remote Branches", location: "-r")
      }
      Spacer()
    }
    .frame(minWidth: 100)
  }
}
