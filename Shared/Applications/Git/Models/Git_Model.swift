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
    
    @Published var logs = [LogEntry]()
    @Published var changes = [String]()
    
    @Published var selectedCommit: LogEntry = LogEntry(commit: "")
    
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
    
    func status() {
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "status", "--porcelain"]) { [self] in
        switch $0 {
        case .complete(_, let array):
          changes.removeAll()
          changes.append(contentsOf: array)
        default: ()
        }
      }
    }
    
    func diff(commit: String, callback: (([DiffLine]) -> ())? = nil) {
      var isReportingDiff = false
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "diff", commit]) {
        switch $0 {
        case .complete(_, let lines):
          var diffLines = [DiffLine]()
          for line in lines {
            if isReportingDiff {
              let status = String(line.first ?? Character(""))
              diffLines.append(DiffLine(line: line, status: status))
              continue
            }

            if line.prefix(2) == "@@" {
              isReportingDiff = true
              continue
            }
          }
          callback?(diffLines)
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
    
    func open(callback: ((URL) -> ())? = nil) {
      let dialog = NSOpenPanel();
      
      dialog.title                   = "Choose single directory | Our Code World";
      dialog.showsResizeIndicator    = true;
      dialog.showsHiddenFiles        = false;
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
    
    func log(branch: String) {
      // look at --oneline
      // loot at --graph without parent
      logs.removeAll()
      try? run(.git, command: ["-C", ViewModel.shared.selectedRepository.path, "log", "--graph", "--abbrev-commit", "--decorate", "--first-parent", "--date=iso-strict", branch.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)]) { [self] in
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
              logEntry?.author = $0
            case let str where str.starts(with: "|     "):
              logEntry?.message.append($0)
            default: ()
            }
          }
          if logEntry != nil {
            // Handle when only a single log is in the repository
            logs.append(logEntry!)
          }
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
