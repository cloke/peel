import SwiftUI

/// A global container for all functions related to Git
struct Git {
  /// Green color as found on github.com
  static let green = Color.init(.sRGB, red: 0.157, green: 0.655, blue: 0.271, opacity: 1.0)
}

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
