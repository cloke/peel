import SwiftUI

struct StashListView: View {
  public let repository: Repository
  @State private var stashes = [String]()
  
  public init(repository: Repository) {
    self.repository = repository
  }
  
  var body: some View {
    DisclosureGroup {
      List(stashes, id: \.self) {
        Text($0)
      }
      .onChange(of: repository.id, perform: { value in
        ViewModel.shared.stashList() {
          self.stashes = $0
        }
      })
      .onAppear() {
        ViewModel.shared.stashList() {
          self.stashes = $0
        }
      }
    } label: {
      HStack {
        Text("Stash")
        Spacer()
        Button {
          ViewModel.shared.stashList() {
            self.stashes = $0
          }
        } label: {
          Image(systemName: "arrow.counterclockwise.icloud")
        }
      }
    }
  }
}

public struct ColumnOneView: View {
  let repository: Repository
  
  public init(repository: Repository) {
    self.repository = repository
  }
  
  public var body: some View {
    VStack {
      List {
        StashListView(repository: repository)
        LocalChangesListView(repository: repository)
        BranchListView(label: "Local Branches", location: "-l")
        BranchListView(label: "Remove Branches", location: "-r")
      }
      Spacer()
    }
    .frame(minWidth: 100)
  }
}
