//
//  WorktreeErrors.swift
//  KitchenSync
//
//  Created on 1/18/26.
//

import Foundation

public enum WorktreeError: LocalizedError {
  case cannotRemoveMain
  case repositoryNotFound(String)
  case commandFailed(String)
  case creationFailed(Error)
  case cleanupFailed(Error)
  case cannotRemove(reason: String)
  case notFound(String)
  case worktreeCreationFailed(String)
  case worktreeRemovalFailed(String)
  case branchCreationFailed(String)
  case gitNotAvailable
  case notSupported
  case gitCommandFailed(String)
  
  public var errorDescription: String? {
    switch self {
    case .cannotRemoveMain:
      return "Cannot remove the main worktree"
    case .repositoryNotFound(let path):
      return "Repository not found at: \(path)"
    case .commandFailed(let output):
      return "Command failed: \(output)"
    case .creationFailed(let error):
      return "Failed to create workspace: \(error.localizedDescription)"
    case .cleanupFailed(let error):
      return "Failed to cleanup workspace: \(error.localizedDescription)"
    case .cannotRemove(let reason):
      return "Cannot remove workspace: \(reason)"
    case .notFound(let id):
      return "Worktree not found: \(id)"
    case .worktreeCreationFailed(let message):
      return "Failed to create worktree: \(message)"
    case .worktreeRemovalFailed(let message):
      return "Failed to remove worktree: \(message)"
    case .branchCreationFailed(let message):
      return "Failed to create branch: \(message)"
    case .gitNotAvailable:
      return "Git is not available"
    case .notSupported:
      return "Workspaces are only supported on macOS"
    case .gitCommandFailed(let message):
      return "Git command failed: \(message)"
    }
  }
}