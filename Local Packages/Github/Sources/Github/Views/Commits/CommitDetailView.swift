//
//  CommitDetailView.swift
//  CommitDetailView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
import Git

struct CommitDetailView: View {
  let commit: Github.Commit
  @State private var commitDetail: Github.CommitDetail?
  @State private var diff: Git.Diff?
  
  var body: some View {
    VStack {
      Text(commit.sha)
        .onAppear {
          Github.commitDetail(from: commit) {
            commitDetail = $0
            var patches = [String]()
            for file in $0.files {
              var patch: [String] = file.patch.components(separatedBy: "\n")
              patch.insert("diff --git", at: 0)
              patches.append(contentsOf: patch)
            }
            diff = Commands.processDiff(lines: patches)
            
          } error: {
            print($0)
          }
        }
      
      if commitDetail != nil {
        Text(commitDetail!.url)
        List(commitDetail!.files) { file in
          Text(file.filename)
        }
      }
      if diff != nil {
        Git.DiffView(diff: diff!)
      }
    }
  }
}




