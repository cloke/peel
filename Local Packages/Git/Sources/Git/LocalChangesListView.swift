//
//  LocalChangesListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

#if os(macOS)
public struct LocalChangesListView: View {
  @Environment(Model.Repository.self) var repository

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
        .keyboardShortcut("r", modifiers: .command)
    }))
  }
}

#Preview {
  LocalChangesListView()
    .environment(Model.Repository(name: "blah", path: "."))
}
#endif
