//
//  CommitsListView.swift
//  CommitsListView
//
//  Created by Cory Loken on 7/18/21.
//

import SwiftUI

struct CommitsListView: View {
  @State private var commits = [Github.Commit]()

  public let repository: Github.Repository
    
  var body: some View {
    List(commits, id: \.sha) { commit in
      VStack {
        NavigationLink(destination: CommitDetailView(commit: commit)) {
          CommitsListItemView(commit: commit)
        }
        Divider()
      }
    }
    .task {
      do {
        commits = try await Github.commits(from: repository)
      } catch {
        print(error)
      }
    }
  }
}
