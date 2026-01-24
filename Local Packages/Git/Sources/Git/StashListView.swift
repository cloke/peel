//
//  StashListView.swift
//
//
//  Created by Cory Loken on 2/22/21.
//

import SwiftUI

#if os(macOS)
struct StashListView: View {
  public let repository: Model.Repository
  @State private var stashes = [String]()
  @State private var isExpanded = false
  
  var body: some View {
    Section(isExpanded: $isExpanded) {
      if stashes.isEmpty {
        Text("No stashes")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(stashes, id: \.self) { stash in
          Text(stash)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    } header: {
      HStack(spacing: 8) {
        Label("Stash", systemImage: "archivebox")
        Spacer()
        if isExpanded {
          Button {
            Task {
              self.stashes = try await Commands.Stash.list(on: repository)
            }
          } label: {
            Image(systemName: "arrow.counterclockwise.icloud")
          }
          .buttonStyle(.plain)
          .help("Refresh")
        }
      }
    }
    .onChange(of: isExpanded) { _, value in
      if isExpanded == true {
        Task {
          self.stashes = try await Commands.Stash.list(on: repository)
        }
      }
    }
  }
}
#endif
