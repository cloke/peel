//
//  CommitDetailView.swift
//  CommitDetailView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
import Foundation
import Git

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

extension Color {
  public static var gitGreen: Color {
    /// Green color as found on github.com
    return Color.init(.sRGB, red: 0.157, green: 0.655, blue: 0.271, opacity: 1.0)
  }
}

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

#Preview {
  DiffView(diff: Diff())
}





