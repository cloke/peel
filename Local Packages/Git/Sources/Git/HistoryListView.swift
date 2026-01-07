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
    NavigationView {
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
      Text("Select a commit")
    }
  }
}

struct HistoryListView_Previews: PreviewProvider {
  static var previews: some View {
    HistoryListView(branch: "Who Knows")
  }
}
#endif
