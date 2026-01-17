//
//  HistoryListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/25/20.
//

import SwiftUI

#if os(macOS)
struct HistoryListView: View {
  @Environment(Model.Repository.self) var repository
  
  @State private var commits = [Model.LogEntry]()
  @State private var diff = Diff()
  @State private var selection: String?
  
  var branch: String
  
  var body: some View {
    HSplitView {
      List(commits, selection: $selection) { commit in
        LogEntryRowView(log: commit)
          .frame(height: 90)
          .padding(.vertical, 4)
          .padding(.horizontal, 2)
          .contentShape(Rectangle())
          .tag(commit.id)
      }
      .listStyle(.inset)
      .frame(minWidth: 0, idealWidth: 360)
      
      DiffView(diff: diff)
        .frame(minWidth: 0)
        .padding(.vertical, 8)
    }
    .navigationTitle("History: \(branch)")
    .task {
      commits = await Commands.log(branch: branch, on: repository)
      if selection == nil, let first = commits.first {
        selection = first.id
      }
    }
    .onChange(of: selection) { _, commit in
      if let commit = commit {
        Task {
          diff = try await Commands.diff(commit: commit, on: repository)
        }
      }
    }
  }
}

#Preview {
  HistoryListView(branch: "main")
    .environment(Model.Repository(name: "test", path: "."))
}
#endif
