//
//  CommitDetailView.swift
//  CommitDetailView
//
//  Created by Cory Loken on 7/16/21.
//

import SwiftUI
import Foundation
import Git

/// This is the same code as the package. Need to figure out how to break up the git package a little better to allow imports of non-platform code.
//public struct Diff: Identifiable {
//  public init(id: UUID = UUID(), files: [Diff.File] = [File]()) {
//    self.id = id
//    self.files = files
//  }
//
//  public var id = UUID()
//  public var files = [File]()
//
//  public struct File: Identifiable {
//    public var id = UUID()
//    public var label = ""
//    public var chunks = [Chunk]()
//
//    public struct Chunk: Identifiable {
//      public var id = UUID()
//      public var chunk = ""
//      public var lines = [Line]()
//
//      /// Identifiable container for single git line diff
//      public struct Line: Identifiable {
//        public var id = UUID()
//        /// The raw output of the line from the command
//        public var line = ""
//        /// The line status. +/- for added / deleted
//        public var status = ""
//        public var lineNumber = 0
//      }
//    }
//  }
//}

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
            diff = Git.Commands.processDiff(lines: patches)
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

/// This is the same code as the package. Need to figure out how to break up the git package a little better to allow imports of non-platform code.
//public struct DiffView: View {
//  public var diff: Diff
//
//  public init(diff: Diff) {
//    self.diff = diff
//  }
//
//  public var body: some View {
//    GeometryReader { geometry in
//      ScrollView([.horizontal, .vertical]) {
//        VStack(alignment: .leading) {
//          ForEach(diff.files) { file in
//            DisclosureGroup(file.label) {
//              ForEach(file.chunks) { chunk in
//                Text(chunk.chunk)
//                ForEach(chunk.lines) { line in
//                  HStack {
//                    if line.lineNumber != 0 {
//                      Text(line.lineNumber.description)
//                        .padding(.leading)
//                    }
//                    Text(line.line)
//                      .padding(.horizontal)
//                    Spacer()
//                  }
//                  .background(lineColor(line.status))
//                }
//              }
//
//            }
//          }
//          Spacer()
//        }
//        .frame(width: geometry.size.width)
//        .frame(minHeight: geometry.size.height)
//      }
//    }
//  }
//
//  func lineColor(_ symbol: String) -> Color {
//    switch symbol {
//    case "+": return .gitGreen
//    case "-": return .red
//    default: return .clear
//    }
//  }
//}

extension Color {
  public static var gitGreen: Color {
    /// Green color as found on github.com
    return Color.init(.sRGB, red: 0.157, green: 0.655, blue: 0.271, opacity: 1.0)
  }
}
//
//func processDiff(lines: [String]) -> Diff {
//  var diff = Diff()
//  let regex = try! NSRegularExpression(
//    pattern: "^(?:(?:@@ -(\\d+),?(\\d+)? \\+(\\d+),?(\\d+)? @@)|([-+\\s])(.*))",
//    options: [])
//  var lineNumber = 0
//  var lineOffset = 0
//  var numberingLines = false
//
//  var currentFile: Diff.File? = nil
//  var currentChunk: Diff.File.Chunk? = nil
//
//  for var line in lines {
//    switch line {
//    // Start of new file
//    case let string where line.starts(with: "diff --git"):
//      // Save all data if there was a file in process
//      if var file = currentFile {
//        if let chunk = currentChunk {
//          file.chunks.append(chunk)
//        }
//        diff.files.append(file)
//      }
//      currentChunk = nil
//      currentFile = Diff.File(label: string)
//      lineNumber = 1 // Probably not the right place
//      lineOffset = 0
//      numberingLines = false
//      continue
//
//    // Process a chunk of the file
//    case let string where line.starts(with: "@@"):
//      let range = NSRange(location: 0, length: string.utf16.count)
//      let match = regex.firstMatch(in: line, options: [], range: range)
//
//      if let chunk = currentChunk {
//        currentFile?.chunks.append(chunk)
//      }
//
//      currentChunk = Diff.File.Chunk()
//      currentChunk?.chunk = match?.group(0, in: line) ?? ""
//
//      lineNumber = Int(match?.group(3, in: line) ?? "0") ?? 0
//      line = line.replacingOccurrences(of: (match?.group(0, in: line) ?? ""), with: "")
//      if line.count > 0 {
//        currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
//      }
//      lineOffset = 0
//      numberingLines = true
//
//    // Ignore these lines. Do we need them?
//    case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "---"): ()
//    case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "+++"): ()
//
//    // Build up actual line diffs
//    case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "-") && numberingLines:
//      lineOffset -= 1
//      currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
//      lineNumber += 1
//
//    case _ where (line.trimmingCharacters(in: .whitespaces).starts(with: "+") || line.starts(with: " ")) && numberingLines:
//      lineNumber += lineOffset
//      lineOffset = 0
//      currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
//      lineNumber += 1
//
//    default: ()
//    }
//  }
//  // This handles the last file in the loop
//  if var file = currentFile {
//    if let chunk = currentChunk {
//      file.chunks.append(chunk)
//    }
//    diff.files.append(file)
//  }
//
//  return diff
//}

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

//struct DiffView_Previews: PreviewProvider {
//  static var previews: some View {
//    DiffView(diff: Diff())
//  }
//}





