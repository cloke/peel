//
//  GitBranchListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/26/20.
//

import SwiftUI

extension Git {
  struct BranchListView: View {
    @ObservedObject private var viewModel = ViewModel()
    @State private var list = [String]()

    var repository: Repository
    var label: String
    var location: String = "-r"
    var callback: ((String) -> ())? = nil
    
    var body: some View {
      DisclosureGroup {
        ForEach(list, id: \.self) { string in
          NavigationLink(destination: HistoryListView(branch: string)) {
            Text(string)
          }
          .background(string.prefix(1) == "*" ? Color.accentColor : Color.clear)
        }
      } label: {
        HStack {
          Text(label)
          Spacer()
          Button {
            viewModel.selectedRepository = repository
            viewModel.showBranches(from: location) {
              list = $0
            }
          } label: {
            Image(systemName: "arrow.counterclockwise.icloud")
          }
        }
      }
    }
  }
}

struct Git_BranchListView_Previews: PreviewProvider {
  static var previews: some View {
    Git.BranchListView(repository: Git.Repository(name: "Test", path: "."), label: "Test")
  }
}
