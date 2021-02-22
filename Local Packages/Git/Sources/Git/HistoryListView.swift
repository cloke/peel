//
//  HistoryListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/25/20.
//

import SwiftUI

struct HistoryListView: View {
  @State private var commits = [LogEntry]()
  @State private var selectedCommit = LogEntry(commit: "")
  @State private var diff = Diff()
  
  var branch: String
  
  var body: some View {
    NavigationView {
      ScrollView {
        LazyVStack(alignment: .leading) {
          ForEach(commits) { commit in
            LogEntryRowView(log: commit)
              .frame(height: 100)
              .contentShape(Rectangle())
              .padding(.vertical, 0)
              .padding(.horizontal, 2)
              .background(selectedCommit.id == commit.id ? Git.green : Color.clear)
              .clipped()
              .onTapGesture {
                selectedCommit = commit
                ViewModel.shared.diff(commit: commit.commit) {
                  diff = $0
                }
              }
            Divider()
              .padding(0)
          }
        }
      }
      .onAppear {
        ViewModel.shared.log(branch: branch) {
          commits = $0
        }
      }
      DiffView(diff: diff)
    }
  }
}

struct HistoryListView_Previews: PreviewProvider {
  static var previews: some View {
    HistoryListView(branch: "Who Knows")
  }
}
