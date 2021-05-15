//
//  LocalChangesListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

public struct LocalChangesListView: View {
  public let repository: Model.Repository

  public var body: some View {
    NavigationLink(destination: FileListView()) {
      HStack {
        Text("Local Changes")
        Spacer()
        Button { Commands.Stash.push(repository: repository) }
          label: {
            Image(systemName: "square.stack.3d.up")
          }
      }
    }
    .contextMenu(ContextMenu(menuItems: {
      Button { Commands.status(on: repository) }
        label: {
          Image(systemName: "arrow.counterclockwise.icloud")
          Text("Refresh")
        }
    }))
  }
}

struct LocalChangesListView_Previews: PreviewProvider {
  static var previews: some View {
    LocalChangesListView(repository: Model.Repository(name: "blah", path: "."))
  }
}
