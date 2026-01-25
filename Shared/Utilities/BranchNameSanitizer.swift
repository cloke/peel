import Foundation

/// Shared branch name sanitization utilities for worktree/branch creation.
///
/// Extracted from duplicated logic in:
/// - Shared/Services/ParallelWorktreeRunner.swift lines ~587-602 (sanitizeBranchComponent)
/// - Shared/AgentOrchestration/WorkspaceManager.swift lines ~71 & ~109 (inline replacingOccurrences)
/// - Local Packages/Github/.../ReviewLocallyService.swift lines ~192-198 (sanitizeBranchName)
/// - Shared/AgentOrchestration/Models/AgentWorkspace.swift lines ~179-186 (inline regex sanitization)
enum BranchNameSanitizer {
  
  /// Sanitizes a text component for use in a Git branch name or worktree folder name.
  ///
  /// Behavior:
  /// - Lowercases input
  /// - Replaces spaces with hyphens
  /// - Replaces special characters (/, \, :) with hyphens
  /// - Keeps only alphanumerics and hyphens
  /// - Collapses consecutive hyphens into single hyphens
  /// - Trims leading/trailing hyphens
  ///
  /// - Parameter text: Input text (e.g., task title, PR branch name)
  /// - Returns: Sanitized component safe for Git branch names and file paths
  static func sanitize(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let slug = text
      .lowercased()
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: " ", with: "-")
      .map { allowed.contains($0.unicodeScalars.first!) ? $0 : "-" }
      .reduce(into: "") { result, character in
        if character == "-" {
          if !result.hasSuffix("-") {
            result.append(character)
          }
        } else {
          result.append(character)
        }
      }
    
    return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}
