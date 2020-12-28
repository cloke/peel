//
//  Git_HistoryListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/25/20.
//

import SwiftUI

extension Git {
  struct HistoryListView: View {
    @State private var commits = [LogEntry]()
    @State private var selectedCommit = LogEntry(commit: "")
    
    var branch: String
    
    var body: some View {
      NavigationView {
        ScrollView {
          LazyVStack(alignment: .leading) {
            ForEach(commits) { commit in
              Git.LogEntryRowView(log: commit)
                .frame(height: 100)
                .clipped()
                .background(selectedCommit.id == commit.id ? Git.green : Color.clear)
                .contentShape(Rectangle())
                .padding(.bottom, 0)
                .onTapGesture {
                  selectedCommit = commit
                }
                .padding(.vertical, 0)
                .padding(.horizontal, 2)
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
        if selectedCommit.commit != "" {
          Git.DiffView(commitOrPath: selectedCommit.commit)
        }
      }
    }
  }
}

struct Git_HistoryListView_Previews: PreviewProvider {
  static var previews: some View {
    Git.HistoryListView(branch: "Who Knows")
  }
}
