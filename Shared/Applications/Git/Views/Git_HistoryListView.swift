//
//  Git_HistoryListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/25/20.
//

import SwiftUI

extension Git {
  struct HistoryListView: View {
    @ObservedObject private var viewModel: ViewModel = .shared
    
    var branch: String
    
    var body: some View {
      NavigationView {
        ScrollView {
          LazyVStack(alignment: .leading) {
            ForEach(viewModel.logs) { log in
              Git.LogEntryRowView(log: log)
                .frame(height: 100)
                .clipped()
                .background(viewModel.selectedCommit.id == log.id ? Git.green : Color.clear)
                .contentShape(Rectangle())
                .padding(.bottom, 0)
                .onTapGesture {
                  viewModel.selectedCommit = log
                }
                .padding(.vertical, 0)
                .padding(.horizontal, 2)
              Divider()
                .padding(0)
            }
          }
        }
        .onAppear {
          viewModel.log(branch: branch)
        }
        if viewModel.selectedCommit.commit != "" {
          Git.DiffView(commitOrPath: viewModel.selectedCommit.commit)
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
