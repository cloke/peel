//
//  File.swift
//  
//
//  Created by Cory Loken on 1/2/21.
//

import SwiftUI
import Combine

extension Array where Element: Equatable{
  mutating func remove (element: Element) {
    if let i = self.firstIndex(of: element) {
      self.remove(at: i)
    }
  }
}

enum FileStatus: String {
  case modifiedMe = ".M"
  case new = "AM"
  case deleted = "D."
  case staged = "M."
  case untracked = "?"
  case renamedMe = "R."
  case ignored = "!"
  case unknown = "**"
}

struct FileDescriptor: Identifiable {
  let id = UUID()
  let path: String
  let status: FileStatus
}

public struct Diff: Identifiable {
  public init(id: UUID = UUID(), files: [Diff.File] = [File]()) {
    self.id = id
    self.files = files
  }
  
  public var id = UUID()
  public var files = [File]()
  
  public struct File: Identifiable {
    public var id = UUID()
    public var label = ""
    public var chunks = [Chunk]()
    
    public struct Chunk: Identifiable {
      public var id = UUID()
      public var chunk = ""
      public var parsedObjectName = ""
      public var lines = [Line]()
      
      /// Identifiable container for single git line diff
      public struct Line: Identifiable {
        public var id = UUID()
        /// The raw output of the line from the command
        public var line = ""
        /// The line status. +/- for added / deleted
        public var status = ""
        public var lineNumber = 0
      }
    }
  }
}

public struct Model {}

/** Identifiable container for single git branch
 
 git branch -l
 */
extension Model {
  public enum BranchType: String {
    case local = "-l", remote = "-r"
  }
  
  public class Branch: Identifiable, ObservableObject {
    public var id = UUID()
    /// Name of the branch
    var name: String
    /// Status of branch from branch command. ie. result started with "*"
    @Published var isActive: Bool
    
    var isSelected = false
    
    init(name: String, isActive: Bool) {
      self.name = name
      self.isActive = isActive
    }
  }
}

extension Model {
  /** Identifiable container for single git log entry
   
   git log --abbrev-commit --graph --decorate --first-parent --date=iso8601-strict
   */
  struct LogEntry: Identifiable {
    var id: String { commit }
    let commit: String
    var merge = ""
    var date = Date()
    var author = ""
    var message = ""
  }
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

#if os(macOS)
public class ViewModel: ObservableObject {
  @AppStorage(wrappedValue: Data(), "repositories") var repositoriesPersisted: Data
  @AppStorage(wrappedValue: Data(), "selected-repository") var selectedRepositoryPersisted: Data
  
  @Published public var repositories = [Model.Repository]()
  @Published public var selectedRepository = Model.Repository(name: "Add Repository", path: "")
  
  public static let shared = ViewModel()
  
  var disposables = Set<AnyCancellable>()
  
  public init() {
    if let repositoriesDecoded = try? JSONDecoder().decode([Model.Repository].self, from: repositoriesPersisted) {
      repositories = repositoriesDecoded
    }
    
    if let selectedRepositoryEncoded = try? JSONDecoder().decode(Model.Repository.self, from: selectedRepositoryPersisted) {
      selectedRepository = selectedRepositoryEncoded
    }
    
    /// Transforms a complex data type to data which is appropriate for storage properties
    $repositories
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink {
        if let repositoriesEncoded = try? JSONEncoder().encode($0) {
          self.repositoriesPersisted = repositoriesEncoded
        }
      }
      .store(in: &disposables)
    /// Transforms a complex data type to data which is appropriate for storage properties
    $selectedRepository
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [self] in
        if let selectedRepositoryEncoded = try? JSONEncoder().encode($0) {
          selectedRepositoryPersisted = selectedRepositoryEncoded
        }
      }
      .store(in: &disposables)
  }
  
  public func resetSettings() {
    repositories = []
    selectedRepository = Model.Repository(name: "Add Repository", path: "")
  }
  
  
  public func addRepository(callback: (() -> ())? = nil) {
    open() { [self] in
      // Check to see if this is a git folder.
      if !FileManager().fileExists(atPath: $0.appendingPathComponent(".git").path) {
        callback?()
        return
      }
      
      let repository = Model.Repository(name: $0.path.components(separatedBy: "/").last ?? "Unknown Name", path: $0.path)
      repositories.append(repository)
      selectedRepository = repository
    }
  }
  
  func open(callback: ((URL) -> ())? = nil) {
    let dialog = NSOpenPanel();
    
    dialog.title = "Choose single directory";
    dialog.showsResizeIndicator = true;
    dialog.showsHiddenFiles = false;
    dialog.canChooseFiles = false;
    dialog.canChooseDirectories = true;
    
    if (dialog.runModal() == NSApplication.ModalResponse.OK) {
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
#endif
