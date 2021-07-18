//
//  CommitsListView.swift
//  CommitsListView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
import Git

extension Github {
  struct CommitDetailView: View {
    let commit: Commit
    @State private var commitDetail: CommitDetail?
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
  
  struct CommitsListView: View {
    public let organization: String
    public let repository: Repository
    
    @EnvironmentObject var viewModel: ViewModel
    @State private var commits = [Github.Commit]()
    
    var body: some View {
      NavigationView {
        List(commits, id: \.sha) { commit in
          NavigationLink(destination: CommitDetailView(commit: commit)) {
            VStack {
              VStack {
                HStack(alignment: .top) {
                  Text(commit.author?.login ?? "Unknown Login")
                  Text(commit.commit.message)
                  Spacer()
                  
                  Text(commit.commit.author.dateFormated)
                }
              }
              Divider()
            }
          }
        }
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
}
