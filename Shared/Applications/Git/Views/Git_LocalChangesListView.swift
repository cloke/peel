//
//  Git_LocalChangesListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

extension Git {
  struct LocalChangesListView: View {
    let repository: Repository
    
    var body: some View {
      // TODO: add counts
      // git rev-list --left-right --count origin/main...main
      NavigationLink(destination: FileListView()) {
        HStack {
          Text("Local Changes")
          Spacer()
          Button { refreshView() }
            label: {
              Image(systemName: "arrow.counterclockwise.icloud")
            }
        }
      }
    }
    
    func refreshView() {
      ViewModel.shared.status()
    }
  }
}

struct Git_LocalChangesListView_Previews: PreviewProvider {
  static var previews: some View {
    Git.LocalChangesListView(repository: Git.Repository(name: "blah", path: "."))
  }
}
