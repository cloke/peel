//
//  LocalChangesListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI

public struct LocalChangesListView: View {
  @Environment(Model.Repository.self) var repository

  public var body: some View {
    HStack(spacing: 8) {
      Label("Local Changes", systemImage: "doc.text")
      Spacer()
      if repository.status.isEmpty {
        Text("Clean")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("\(repository.status.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
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
