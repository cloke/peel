//
//  ToolDefinition.swift
//  MCPCore
//
//  MCP tool definition types.
//

import Foundation

// MARK: - Tool Category

/// Categories for MCP tools
public enum MCPToolCategory: String, CaseIterable, Codable, Sendable {
  case chains
  case parallelWorktrees
  case logs
  case server
  case app
  case diagnostics
  case ui
  case state
  case rag
  case vm
  case swarm
  case worktrees

  public var displayName: String {
    switch self {
    case .chains: return "Chains"
    case .parallelWorktrees: return "Parallel Worktrees"
    case .logs: return "Logs"
    case .server: return "Server"
    case .app: return "App"
    case .diagnostics: return "Diagnostics"
    case .ui: return "UI Automation"
    case .state: return "State"
    case .rag: return "Local RAG"
    case .vm: return "VM Isolation"
    case .swarm: return "Distributed Swarm"
    case .worktrees: return "Worktrees"
    }
  }
}

// MARK: - Tool Group

/// Behavioral groups for MCP tools (permissions/safety)
public enum MCPToolGroup: String, CaseIterable, Codable, Sendable {
  case screenshots
  case uiNavigation
  case mutating
  case backgroundSafe

  public var displayName: String {
    switch self {
    case .screenshots: return "Screenshots"
    case .uiNavigation: return "UI Navigation"
    case .mutating: return "Mutating"
    case .backgroundSafe: return "Background-safe"
    }
  }
}

// MARK: - Tool Definition

/// Definition of an MCP tool
public struct MCPToolDefinition: Identifiable, Sendable {
  public let name: String
  public let description: String
  public let inputSchema: [String: Any]
  public let category: MCPToolCategory
  public let isMutating: Bool
  public let requiresForeground: Bool

  public var id: String { name }

  public init(
    name: String,
    description: String,
    inputSchema: [String: Any],
    category: MCPToolCategory,
    isMutating: Bool,
    requiresForeground: Bool = false
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.category = category
    self.isMutating = isMutating
    self.requiresForeground = requiresForeground
  }

  /// Convert inputSchema to JSON-encodable dictionary
  public var inputSchemaJSON: [String: Any] {
    inputSchema
  }
}

// MARK: - Tool Permission

/// Tool permission settings
public struct MCPToolPermission: Codable, Sendable {
  public let toolName: String
  public var isEnabled: Bool

  public init(toolName: String, isEnabled: Bool = true) {
    self.toolName = toolName
    self.isEnabled = isEnabled
  }
}

// MARK: - Tool List Entry

/// Entry in the MCP tools/list response
public struct MCPToolListEntry: Codable, Sendable {
  public let name: String
  public let description: String
  public let inputSchema: [String: AnyCodable]

  public init(name: String, description: String, inputSchema: [String: AnyCodable]) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }

  public init(from definition: MCPToolDefinition) {
    self.name = definition.name
    self.description = definition.description
    self.inputSchema = definition.inputSchema.mapValues { AnyCodable($0) }
  }
}
