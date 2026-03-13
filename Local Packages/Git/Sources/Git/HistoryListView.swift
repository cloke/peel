//
//  HistoryListView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/25/20.
//

import SwiftUI

struct HistoryListView: View {
  @Environment(Model.Repository.self) var repository
  
  @State private var commits = [Model.LogEntry]()
  @State private var diff = Diff()
  @State private var selection: String?
  @AppStorage("git.selectedCommitSha") private var selectedCommitSha: String = ""
  
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
      .frame(minWidth: 200, idealWidth: 280, maxWidth: 360)
      
      DiffView(diff: diff)
        .frame(minWidth: 0, idealWidth: 0)
        .layoutPriority(1)
        .padding(.vertical, 8)
    }
    .navigationTitle("History: \(branch)")
    .task {
      commits = await Commands.log(branch: branch, on: repository)
      persistAvailableCommits()
      if selection == nil, let first = commits.first {
        selection = first.id
      }
    }
    .onChange(of: selection) { _, commit in
      if let commit = commit {
        if selectedCommitSha != commit {
          selectedCommitSha = commit
        }
        Task {
          diff = try await Commands.diff(commit: commit, on: repository)
        }
      }
    }
    .onChange(of: selectedCommitSha) { _, newValue in
      guard !newValue.isEmpty, selection != newValue else { return }
      if commits.contains(where: { $0.id == newValue }) {
        selection = newValue
      }
    }
  }

  private func persistAvailableCommits() {
    let shas = commits.map { $0.id }
    UserDefaults.standard.set(shas, forKey: "git.availableCommitShas")
  }
}

#Preview {
  HistoryListView(branch: "main")
    .environment(Model.Repository(name: "test", path: "."))
}
