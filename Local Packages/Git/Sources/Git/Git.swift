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

public struct RepositoriesToolbarItem: ToolbarContent {
  public let repositories: [Repository]
  @Binding public var selectedRepository: Repository
  
  public init(repositories: [Repository], selectedRepository: Binding<Repository>) {
    self.repositories = repositories
    self._selectedRepository = selectedRepository
  }
  
  public var body: some ToolbarContent {
    ToolbarItem(placement: ToolbarItemPlacement.primaryAction) {
      Menu(selectedRepository.name) {
        ForEach(repositories) { repository in
          Button(repository.name) {
            selectedRepository = repository
          }
        }
      }
    }
  }
}
