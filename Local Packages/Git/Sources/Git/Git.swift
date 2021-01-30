import SwiftUI

public struct ColumnOneView: View {
  let repository: Repository
  
  public init(repository: Repository) {
    self.repository = repository
  }
  
  public var body: some View {
    VStack {
      List {
        LocalChangesListView(repository: repository)
        BranchListView(label: "Local Branches", location: "-l")
        BranchListView(label: "Remove Branches", location: "-r")
      }
      Spacer()
    }
    .frame(minWidth: 100)
  }
}
