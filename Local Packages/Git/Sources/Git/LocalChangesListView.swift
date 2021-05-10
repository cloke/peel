//
//  LocalChangesListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

public struct LocalChangesListView: View {
  public let repository: Repository
  
  public init(repository: Repository) {
    self.repository = repository
  }
  
  public var body: some View {
    // TODO: add counts
    // git rev-list --left-right --count origin/main...main
    NavigationLink(destination: FileListView()) {
      HStack {
        Text("Local Changes")
        Spacer()
        Button { ViewModel.Stash.push() }
          label: {
            Image(systemName: "square.stack.3d.up")
          }
      }
    }
    .contextMenu(ContextMenu(menuItems: {
      
      Button { refreshView() }
        label: {
          Image(systemName: "arrow.counterclockwise.icloud")
          Text("Refresh")
        }
      
    }))
  }
  
  func refreshView() {
    ViewModel.shared.status()
  }
}

struct LocalChangesListView_Previews: PreviewProvider {
  static var previews: some View {
    LocalChangesListView(repository: Repository(name: "blah", path: "."))
  }
}
