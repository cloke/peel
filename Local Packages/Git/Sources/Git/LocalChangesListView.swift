//
//  LocalChangesListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

#if os(macOS)
public struct LocalChangesListView: View {
  @EnvironmentObject var repository: Model.Repository

  public var body: some View {
    NavigationLink(destination: FileListView(repository: repository)) {
      HStack {
        Text("Local Changes (\(repository.status.count))")
      }
    }
    .contextMenu(ContextMenu(menuItems: {
      Button {
        Task { try? await Commands.status(on: repository) }
      } label: {
          Image(systemName: "arrow.counterclockwise.icloud")
          Text("Refresh")
        }
    }))
  }
}

struct LocalChangesListView_Previews: PreviewProvider {
  static var previews: some View {
    LocalChangesListView()
      .environmentObject(Model.Repository(name: "blah", path: "."))
  }
}
#endif

