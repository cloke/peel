//
//  HistoryListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/25/20.
//

import SwiftUI

struct HistoryListView: View {
  @State private var commits = [Model.LogEntry]()
  @State private var selectedCommit = Model.LogEntry(commit: "")
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
              .background(selectedCommit.id == commit.id ? Color.gitGreen : Color.clear)
              .clipped()
              .onTapGesture {
                selectedCommit = commit
                Commands.diff(commit: commit.commit, on: ViewModel.shared.selectedRepository) {
                  diff = $0
                }
              }
            Divider()
              .padding(0)
          }
        }
      }
      .onAppear {
        Commands.log(branch: branch, on: ViewModel.shared.selectedRepository) {
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
