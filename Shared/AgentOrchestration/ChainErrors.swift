//
//  ChainErrors.swift
//  Peel
//
//  Consolidated chain error types to avoid duplication.
//

import Foundation

// MARK: - Chain Execution Errors

/// Errors that occur during chain execution (used by AgentChainRunner)
public enum ChainExecutionError: LocalizedError, SimpleMessageError {
  case reviewRejected(reason: String)
  case cancelled

  public var errorDescription: String? { defaultErrorDescription }

  public var messageValue: String? {
    switch self {
    case .reviewRejected(let reason):
      return "Review rejected: \(reason.prefix(200))..."
    case .cancelled:
      return "Chain cancelled"
    }
  }
}

// MARK: - Chain API Errors

/// Errors for MCP chain management API (used by MCPServerService)
public enum ChainAPIError: LocalizedError {
  case queueFull
  case templateNotFound
  case cancelled
  case notFound
  case invalidChainId
  case missingFeedback
  case invalidAction(String)
  case invalidConfiguration(String)
  case startFailed(String)

  public var errorDescription: String? {
    switch self {
    case .queueFull: return "Chain queue is full"
    case .templateNotFound: return "Template not found"
    case .cancelled: return "Chain run was cancelled"
    case .notFound: return "Chain not found"
    case .invalidChainId: return "Invalid chain ID"
    case .missingFeedback: return "Feedback required for this action"
    case .invalidAction(let action): return "Invalid action: \(action)"
    case .invalidConfiguration(let msg): return "Invalid configuration: \(msg)"
    case .startFailed(let msg): return "Failed to start chain: \(msg)"
    }
  }
}
