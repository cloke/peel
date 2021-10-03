//
//  CommitsListView.swift
//  CommitsListView
//
//  Created by Cory Loken on 7/18/21.
//

import SwiftUI

struct CommitsListView: View {
  public let repository: Github.Repository
  
  @EnvironmentObject var viewModel: Github.ViewModel
  @State private var commits = [Github.Commit]()
  
  var body: some View {
    Group {
#if os(macOS)
    NavigationView {
      List(commits, id: \.sha) { commit in
        VStack {
          NavigationLink(destination: CommitDetailView(commit: commit)) {
            CommitsListItemView(commit: commit)
          }
          Divider()
        }
      }
    }
#else
    List(commits, id: \.sha) { commit in
      VStack {
        NavigationLink(destination: CommitDetailView(commit: commit)) {
          CommitsListItemView(commit: commit)
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
#endif
    }
    .onAppear {
      Github.commits(from: repository) {
        commits = $0
      } error: {
        print($0)
      }
    }
  }
}
