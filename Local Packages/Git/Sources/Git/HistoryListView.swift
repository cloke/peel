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
    List(commits, selection: $selection) { commit in
      NavigationLink(
        destination: DiffView(diff: diff)
          .padding()
      ) {
        VStack {
          LogEntryRowView(log: commit)
            .frame(height: 90)
            .padding(.vertical, 0)
            .padding(.horizontal, 2)
          Divider()
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("History: \(branch)")
    .task {
      commits = await Commands.log(branch: branch, on: repository)
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
