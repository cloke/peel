//
//  MCPToolHandler.swift
//  KitchenSync
//
//  Created as part of #121: Split MCPServerService by tool category.
//

import Foundation
import MCPCore

// MARK: - Tool Handler Protocol

/// Protocol for tool handlers extracted from MCPServerService.
/// Each handler manages a category of MCP tools.
@MainActor
public protocol MCPToolHandler {
  /// The service delegate for shared functionality
  var delegate: MCPToolHandlerDelegate? { get set }

  /// Tool names this handler supports
  var supportedTools: Set<String> { get }

  /// Handle a tool call
  /// - Parameters:
  ///   - name: The tool name
  ///   - id: The RPC request ID
  ///   - arguments: The tool arguments
  /// - Returns: Tuple of (HTTP status code, response data)
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data)
}

// MARK: - Handler Delegate Protocol

/// Delegate protocol providing shared MCPServerService functionality to handlers.
@MainActor
public protocol MCPToolHandlerDelegate: AnyObject {
  // MARK: - UI State Management

  /// Record that a UI action was handled
  func recordUIActionHandled(_ controlId: String)

  /// Record that a UI action was requested
  func recordUIActionRequested(_ controlId: String)

  /// Record that a UI action needs the app in foreground
  func recordUIActionForegroundNeeded(_ controlId: String)

  /// Get available view IDs
  func availableViewIds() -> [String]

  /// Get available tool control IDs
  func availableToolControlIds() -> [String]

  /// Get available control IDs for a view
  func availableControlIds(for viewId: String?) -> [String]

  /// Get control values for a view
  func controlValues(for viewId: String?) -> [String: Any]

  /// Get current tool/view ID
  func currentToolId() -> String?

  /// Set current tool/view ID
  func setCurrentToolId(_ viewId: String)

  /// Worktree name map from defaults
  func worktreeNameMapFromDefaults() -> [String: String]

  // MARK: - Service Properties Access

  /// Local RAG repo path
  var localRagRepoPath: String { get set }

  /// Local RAG query string
  var localRagQuery: String { get set }

  /// Local RAG use CoreML toggle
  var localRagUseCoreML: Bool { get set }

  /// Local RAG search mode
  var localRagSearchMode: MCPServerService.RAGSearchMode { get set }

  /// Local RAG search limit
  var localRagSearchLimit: Int { get set }

  /// Last UI action
  var lastUIAction: UIAction? { get set }
}

// MARK: - Response Builder Convenience

/// Extension providing convenient response builders using MCPCore
extension MCPToolHandler {
  /// Create a successful RPC result response
  public func makeResult(id: Any?, result: [String: Any]) -> Data {
    JSONRPCResponseBuilder.makeResult(id: id, result: result)
  }

  /// Create an error RPC response
  public func makeError(id: Any?, code: Int, message: String, data: [String: Any]? = nil) -> Data {
    JSONRPCResponseBuilder.makeError(id: id, code: code, message: message, data: data)
  }

  /// Create an error RPC response without data
  public func makeError(id: Any?, code: Int, message: String) -> Data {
    JSONRPCResponseBuilder.makeError(id: id, code: code, message: message)
  }
}
