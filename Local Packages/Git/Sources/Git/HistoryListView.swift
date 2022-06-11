//
//  HistoryListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/25/20.
//

import SwiftUI

#if os(macOS)
struct HistoryListView: View {
  @EnvironmentObject var repository: Model.Repository
  
  @State private var commits = [Model.LogEntry]()
  @State private var diff = Diff()
  @State private var selection: String?
  
  var branch: String
  
  var body: some View {
    List(commits, selection: $selection) { commit in
      NavigationLink(destination: DiffView(diff: diff)) {
        LogEntryRowView(log: commit)
          .frame(height: 90)
          .padding(.vertical, 0)
          .padding(.horizontal, 2)
      }
    }
    .listStyle(.sidebar)
    .task {
      commits = await Commands.log(branch: branch, on: repository)

    }
    .onChange(of: selection) { commit in
      if let commit = commit {
        Commands.diff(commit: commit, on: repository) {
          diff = $0
        }
      }
    }
  }
}

struct HistoryListView_Previews: PreviewProvider {
  static var previews: some View {
    HistoryListView(branch: "Who Knows")
  }
}
#endif
