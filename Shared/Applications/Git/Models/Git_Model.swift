//
//  Model.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/20/20.
//

// The root namespace for all functions related to brew

import SwiftUI
import Combine

/// A global container for all functions related to Git
struct Git {
  /// Green color as found on github.com
  static let green = Color.init(.sRGB, red: 0.157, green: 0.655, blue: 0.271, opacity: 1.0)
}

extension Git {
  /// Identifiable container for single git line diff
  struct DiffLine: Identifiable {
    var id = UUID()
    /// The raw output of the line from the command
    var line = ""
    /// The line status. +/- for added / deleted
    var status = ""
    var lineNumber = 0
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
  struct Repository: Codable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
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
}

extension Git {
  class ViewModel: TaskRunnerProtocol, ObservableObject {
    static let shared = ViewModel()

    @AppStorage(wrappedValue: Data(), "repositories") var repositoriesPersisted: Data
    @AppStorage(wrappedValue: Data(), "selected-repository") var selectedRepositoryPersisted: Data

    @Published var repositories = [Repository]()
    @Published var selectedRepository = Repository(name: "Add Repository", path: "")
        
    private var disposables = Set<AnyCancellable>()
    
    init() {
      if let repositoriesDecoded = try? JSONDecoder().decode([Repository].self, from: repositoriesPersisted) {
        repositories = repositoriesDecoded
      }
      
      if let selectedRepositoryEncoded = try? JSONDecoder().decode(Repository.self, from: selectedRepositoryPersisted) {
        selectedRepository = selectedRepositoryEncoded
      }
      
      $repositories
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink {
          if let repositoriesEncoded = try? JSONEncoder().encode($0) {
            self.repositoriesPersisted = repositoriesEncoded
          }
        }
        .store(in: &disposables)
      
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
    
    func resetSettings() {
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

    func processDiff(lines: [String]) -> [DiffLine] {
      var diffLines = [DiffLine]()
      let regex = try! NSRegularExpression(
              pattern: "^(?:(?:@@ -(\\d+),?(\\d+)? \\+(\\d+),?(\\d+)? @@)|([-+\\s])(.*))",
              options: [])
      var lineNumber = 0
      var numberingLines = false
      var lineOffset = 0
      
      for line in lines {
        if line.starts(with: "@@") {
          let range = NSRange(location: 0, length: line.utf16.count)
          let match = regex.firstMatch(in: line, options: [], range: range)
          lineNumber = (Int(match?.group(1, in: line) ?? "0") ?? 0) - 1
          lineOffset = 0
          numberingLines = true
        } else if line.starts(with: "diff --git") {
          lineNumber = 0
          lineOffset = 0
          numberingLines = false
        }
        
        if line.trimmingCharacters(in: .whitespaces).starts(with: "-") && numberingLines {
          lineOffset -= 1
        }
        
        if (line.trimmingCharacters(in: .whitespaces).starts(with: "+") || line.starts(with: " "))
            && numberingLines {
          lineNumber += lineOffset
          lineOffset = 0
        }

        diffLines.append(DiffLine(line: line, status: String(line.first ?? Character("")), lineNumber: lineNumber))
        if numberingLines {
          lineNumber += 1
        }
      }
      return diffLines
    }
    
    func diff(path: String, callback: (([DiffLine]) -> ())? = nil) {
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "diff", path]) {
        switch $0 {
        case .complete(_, let lines):
          callback?(self.processDiff(lines: lines))
        default: ()
        }
      }
    }
    
    func diff(commit: String, callback: (([DiffLine]) -> ())? = nil) {
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "diff", "\(commit)~", commit]) {
        switch $0 {
        case .complete(_, let lines):
          callback?(self.processDiff(lines: lines))
        default: ()
        }
      }
    }
    
    func pull() {
      
    }
    
    func checkout(branch: String, callback: (() -> ())? = nil) {
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "checkout", branch]) {
        print($0)
        callback?()
      }
    }
    
    func commit(message: String, callback: (() -> ())? = nil) {
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "commit", "-am", message]) { _ in
        callback?()
      }
    }
    
    func add(path: String) {
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "add", path])
    }
    
    func unadd(path: String) {
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "reset", "HEAD", path])
    }
    
    func open(callback: ((URL) -> ())? = nil) {
//      let dialog = NSOpenPanel();
//      
//      dialog.title                   = "Choose single directory | Our Code World";
//      dialog.showsResizeIndicator    = true;
//      dialog.showsHiddenFiles        = false;
//      dialog.canChooseFiles = false;
//      dialog.canChooseDirectories = true;
//      
//      if (dialog.runModal() ==  NSApplication.ModalResponse.OK) {
//        let result = dialog.url
//        if (result != nil) {
//          callback?(result!)
//        }
//      } else {
//        // User clicked on "Cancel"
//        return
//      }
    }
    
    func addRepository(callack: (() -> ())? = nil) {
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
  }
}
