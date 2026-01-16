//
//  CommitDetailView.swift
//  CommitDetailView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
import Foundation
import Git

#if os(macOS)
struct CommitDetailView: View {
  let commit: Github.Commit
  @State private var commitDetail: Github.CommitDetail?
  @State private var diff: Diff?
  
  var body: some View {
    VStack {
      Text(commit.sha)
        .task {
          do {
            commitDetail = try await Github.commitDetail(from: commit)
            var patches = [String]()
            for file in commitDetail!.files {
              var patch: [String] = file.patch.components(separatedBy: "\n")
              patch.insert("diff --git", at: 0)
              patches.append(contentsOf: patch)
            }
            diff = Commands.processDiff(lines: patches)
          } catch {
            print(error)
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
#endif

// Note: Color.gitGreen is defined in Git package (Git/Extensions/Color.swift)
// The Github package imports Git, so it has access to this extension.

internal extension NSTextCheckingResult {
  func group(_ group: Int, in string: String) -> String? {
    let nsRange = range(at: group)
    if range.location != NSNotFound {
      return Range(nsRange, in: string)
        .map { range in String(string[range]) }
    }
    return nil
  }
}

#if os(macOS)
#Preview {
  DiffView(diff: Diff())
}
#endif





