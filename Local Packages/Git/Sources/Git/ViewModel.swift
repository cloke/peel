//
//  File.swift
//  
//
//  Created by Cory Loken on 1/2/21.
//

import Foundation
import TaskRunner
import SwiftUI
import Combine

/// A global container for all functions related to Git
struct Git {
  /// Green color as found on github.com
  static let green = Color.init(.sRGB, red: 0.157, green: 0.655, blue: 0.271, opacity: 1.0)
}

struct Diff: Identifiable {
  var id = UUID()
  var files = [File]()
  
  struct File: Identifiable {
    var id = UUID()
    var label = ""
    var chunks = [Chunk]()
    
    struct Chunk: Identifiable {
      var id = UUID()
      var chunk = ""
      var lines = [Line]()

      /// Identifiable container for single git line diff
      struct Line: Identifiable {
        var id = UUID()
        /// The raw output of the line from the command
        var line = ""
        /// The line status. +/- for added / deleted
        var status = ""
        var lineNumber = 0
      }
    }
  }
}
/** Identifiable container for single git branch

  git branch -l
*/
struct Branch: Identifiable {
  var id = UUID()
  /// Name of the branch
  var name: String
  /// Status of branch from branch command. ie. result started with "*"
  var isActive = false
}

/// Identifiable container for single git repository
public struct Repository: Codable, Identifiable {
  public var id = UUID()
  public var name: String
  public var path: String
}

/** Identifiable container for single git log entry

  git log --abbrev-commit --graph --decorate --first-parent --date=iso8601-strict
*/
struct LogEntry: Identifiable {
  var id: String { commit }
  let commit: String
  var merge = ""
  var date = Date()
  var author = ""
  var message = [String]()
}

enum GitError: Error {
  case Unknown
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

public class ViewModel: TaskRunnerProtocol, ObservableObject {
  public static let shared = ViewModel()

  @AppStorage(wrappedValue: Data(), "repositories") var repositoriesPersisted: Data
  @AppStorage(wrappedValue: Data(), "selected-repository") var selectedRepositoryPersisted: Data

  @Published public var repositories = [Repository]()
  @Published public var selectedRepository = Repository(name: "Add Repository", path: "")
      
  private var disposables = Set<AnyCancellable>()
  
  init() {
    if let repositoriesDecoded = try? JSONDecoder().decode([Repository].self, from: repositoriesPersisted) {
      repositories = repositoriesDecoded
    }
    
    if let selectedRepositoryEncoded = try? JSONDecoder().decode(Repository.self, from: selectedRepositoryPersisted) {
      selectedRepository = selectedRepositoryEncoded
    }
    
    /// Transforms a compalex data type to data which is appropriate for storage properties
    $repositories
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink {
        if let repositoriesEncoded = try? JSONEncoder().encode($0) {
          self.repositoriesPersisted = repositoriesEncoded
        }
      }
      .store(in: &disposables)
    /// Transforms a compalex data type to data which is appropriate for storage properties
    $selectedRepository
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink {
        if let selectedRepositoryEncoded = try? JSONEncoder().encode($0) {
          self.selectedRepositoryPersisted = selectedRepositoryEncoded
        }
      }
      .store(in: &disposables)
  }
  
  public func resetSettings() {
    repositories = []
    selectedRepository = Repository(name: "Add Repository", path: "")
  }
  
  func status(callback: (([String]) -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "status", "--porcelain"]) {
      switch $0 {
      case .complete(_, let array):
        callback?(array)
      default: ()
      }
    }
  }
  
  /// - Group 1: The header old file line start.
  /// - Group 2: The header old file line span. If not present it defaults to 1.
  /// - Group 3: The header new file line start.
  /// - Group 4: The header new file line span. If not present it defaults to 1.
  
  // Huge help from https://github.com/guillermomuntaner/GitDiff/

  func processDiff(lines: [String]) -> Diff {
    var diff = Diff()
    let regex = try! NSRegularExpression(
            pattern: "^(?:(?:@@ -(\\d+),?(\\d+)? \\+(\\d+),?(\\d+)? @@)|([-+\\s])(.*))",
            options: [])
    var lineNumber = 0
    var lineOffset = 0
    var numberingLines = false

    var currentFile: Diff.File? = nil
    var currentChunk: Diff.File.Chunk? = nil
        
    for var line in lines {
      switch line {
      // Start of new file
      case let string where line.starts(with: "diff --git"):
        // Save all data if there was a file in process
        if var file = currentFile {
          if let chunk = currentChunk {
            file.chunks.append(chunk)
          }
          diff.files.append(file)
        }
        currentChunk = nil
        currentFile = Diff.File(label: string)
        lineNumber = 1 // Probably not the right place
        lineOffset = 0
        numberingLines = false
        continue
      
      // Process a chunk of the file
      case let string where line.starts(with: "@@"):
        let range = NSRange(location: 0, length: string.utf16.count)
        let match = regex.firstMatch(in: line, options: [], range: range)

        if let chunk = currentChunk {
          currentFile?.chunks.append(chunk)
        }
        
        currentChunk = Diff.File.Chunk()
        currentChunk?.chunk = match?.group(0, in: line) ?? ""
        
        lineNumber = Int(match?.group(3, in: line) ?? "0") ?? 0
        line = line.replacingOccurrences(of: (match?.group(0, in: line) ?? ""), with: "")
        if line.count > 0 {
          currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
        }
        lineOffset = 0
        numberingLines = true
      
      // Ignore these lines. Do we need them?
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "---"): ()
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "+++"): ()

      // Build up actual line diffs
      case _ where line.trimmingCharacters(in: .whitespaces).starts(with: "-") && numberingLines:
        lineOffset -= 1
        currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
        lineNumber += 1

      case _ where (line.trimmingCharacters(in: .whitespaces).starts(with: "+") || line.starts(with: " ")) && numberingLines:
        lineNumber += lineOffset
        lineOffset = 0
        currentChunk?.lines.append(Diff.File.Chunk.Line(line: line, status: String(line.first ?? Character(" ")), lineNumber: lineNumber))
        lineNumber += 1

      default:
        print("WTF: \(line)")
      }
    }
    // This handles the last file in the loop
    if var file = currentFile {
      if let chunk = currentChunk {
        file.chunks.append(chunk)
      }
      diff.files.append(file)
    }
    
    return diff
  }
  
  func diff(path: String, callback: ((Diff) -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "diff", path]) {
      switch $0 {
      case .complete(_, let lines):
        callback?(self.processDiff(lines: lines))
      default: ()
      }
    }
  }
  
  func diff(commit: String, callback: ((Diff) -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "diff", "\(commit)~", commit]) {
      switch $0 {
      case .complete(_, let lines):
        callback?(self.processDiff(lines: lines))
      default: ()
      }
    }
  }
  
  func pull(branch: String) {
    
  }
  
  func revList(branchA: String, branchB: String, callback: ((Int, Int) -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "rev-list", "--left-right", "--count", "\(branchA)...\(branchB)"]) {
      switch $0 {
      case .complete(_, let lines):
        /// tab separated to left and right value
        if let t = lines.first?.split(separator: "\t"), let l = Int(t.first ?? "0"), let r = Int(t.last ?? "0") {
          callback?(l, r)
        }
      default: ()
      }
    }
  }
  
  func push(branch: String, callback: (() -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "push", "origin", branch]) {
      switch $0 {
      case .complete(_, _):
      callback?()
      default: ()
      }
    }
  }
  
  func checkout(branch: String, callback: (() -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "checkout", branch]) {
      switch $0 {
      case .complete(_, _):
      callback?()
      default: ()
      }
    }
  }
  
  func commit(message: String, callback: (([String], Error? ) -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "commit", "-am", message]) {
      switch $0 {
      case .complete(_, let array):
      callback?(array, nil)
      default: ()
      }
    }
  }
  
  func add(path: String, callack: (([String], GitError?) -> ())? = nil) {
    do {
    try run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "add", path]) {
      switch $0 {
      case .complete(_, let array):
        callack?(array, nil)
      default: ()
      }
    }
    } catch {
      callack?([], .Unknown)

    }
  }
  
  func unadd(path: String, callack: (() -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "reset", "HEAD", path])
  }
  
  public func addRepository(callack: (() -> ())? = nil) {
    open() { [self] in
      // Check to see if this is a git folder.
      if !FileManager().fileExists(atPath: $0.appendingPathComponent(".git").path) {
        callack?()
        return
      }
      
      let repository = Repository(name: $0.path.components(separatedBy: "/").last ?? "Unknown Name", path: $0.path)
      repositories.append(repository)
      selectedRepository = repository
    }
  }
  
  func log(branch: String, callack: (([LogEntry]) -> ())? = nil) {
    // look at --oneline
    // loot at --graph without parent
    var logs = [LogEntry]()
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "log", "--graph", "--abbrev-commit", "--decorate", "--first-parent", "--date=iso-strict", branch.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)]) {
      switch $0 {
      case .complete(_, let array):
        var logEntry: LogEntry?
        
        array.forEach {
          switch $0 {
          case let str where str.starts(with: "*"):
            if logEntry != nil { logs.append(logEntry!) }
            logEntry = LogEntry(commit: String($0.split(separator: " ")[2]))
          case let str where str.starts(with: "| Date:"):
            let dateFormatter = ISO8601DateFormatter()
            logEntry?.date = dateFormatter.date(from: String($0.dropFirst(7))) ?? Date()
          case let str where str.starts(with: "| Merge:"):
            logEntry?.merge = $0
          case let str where str.starts(with: "| Author:"):
            logEntry?.author = String($0.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
          case let str where str.starts(with: "|     "):
            logEntry?.message.append(String($0.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines))
          default: ()
          }
        }
        if logEntry != nil {
          // Handle when only a single log is in the repository
          logs.append(logEntry!)
        }
        callack?(logs)
        default: ()
      }
    }
  }
  
  // git log --pretty=short
  // git shortlog
  // git shortlog -scen
  func showBranches(from location: String = "-r", callback: (([Branch]) -> ())? = nil) {
    try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "branch", location]) {
      switch $0 {
      case .complete(_, let array):
        callback?(array.map {
          return Branch(
            name: $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
            isActive: $0.starts(with: "*")
          )
        })
      default: ()
      }
    }
  }
  
  func open(callback: ((URL) -> ())? = nil) {
    let dialog = NSOpenPanel();
    
    dialog.title = "Choose single directory";
    dialog.showsResizeIndicator = true;
    dialog.showsHiddenFiles = false;
    dialog.canChooseFiles = false;
    dialog.canChooseDirectories = true;
    
    if (dialog.runModal() ==  NSApplication.ModalResponse.OK) {
      let result = dialog.url
      if (result != nil) {
        callback?(result!)
      }
    } else {
      // User clicked on "Cancel"
      return
    }
  }
}
