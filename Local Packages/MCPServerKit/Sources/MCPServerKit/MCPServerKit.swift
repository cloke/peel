//
//  MCPServerKit.swift
//  MCPServerKit
//
//  A reusable MCP server framework for embedding in any macOS/iOS app.
//
//  This package provides:
//  - JSON-RPC 2.0 HTTP server
//  - Tool registry and dispatch
//  - Configuration abstraction
//  - Tool handler protocol
//

@_exported import MCPCore
import Foundation
import Network

// MARK: - Server Configuration

/// Protocol for MCP server configuration providers.
/// Implement this to supply settings from UserDefaults, config files, or environment.
@MainActor
public protocol MCPServerConfigProviding: AnyObject, Sendable {
  func bool(forKey key: String, default defaultValue: Bool) -> Bool
  func integer(forKey key: String, default defaultValue: Int) -> Int
  func string(forKey key: String, default defaultValue: String) -> String
  func stringArray(forKey key: String) -> [String]
  func data(forKey key: String) -> Data?
  func objectExists(forKey key: String) -> Bool
  func set(_ value: Bool, forKey key: String)
  func set(_ value: Int, forKey key: String)
  func set(_ value: String, forKey key: String)
  func set(_ value: Data?, forKey key: String)
}

/// Default configuration provider backed by UserDefaults.
@MainActor
public final class MCPUserDefaultsConfig: MCPServerConfigProviding {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func bool(forKey key: String, default defaultValue: Bool) -> Bool {
    if defaults.object(forKey: key) == nil {
      return defaultValue
    }
    return defaults.bool(forKey: key)
  }

  public func integer(forKey key: String, default defaultValue: Int) -> Int {
    if defaults.object(forKey: key) == nil {
      return defaultValue
    }
    return defaults.integer(forKey: key)
  }

  public func string(forKey key: String, default defaultValue: String) -> String {
    defaults.string(forKey: key) ?? defaultValue
  }

  public func stringArray(forKey key: String) -> [String] {
    defaults.stringArray(forKey: key) ?? []
  }

  public func data(forKey key: String) -> Data? {
    defaults.data(forKey: key)
  }

  public func objectExists(forKey key: String) -> Bool {
    defaults.object(forKey: key) != nil
  }

  public func set(_ value: Bool, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: Int, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: String, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: Data?, forKey key: String) {
    defaults.set(value, forKey: key)
  }
}

// MARK: - Tool Handler Protocol

/// Protocol for MCP tool handlers.
/// Each handler manages a category of tools and dispatches calls.
@MainActor
public protocol MCPToolHandling: AnyObject {
  /// Tool names this handler supports
  var supportedTools: Set<String> { get }

  /// Handle a tool call
  /// - Returns: Tuple of (HTTP status code, response data)
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data)
}

// MARK: - Tool Registry

/// Registry for MCP tool definitions and handlers.
@MainActor
public final class MCPToolRegistry {
  private var definitions: [MCPToolDefinition] = []
  private var handlers: [MCPToolHandling] = []
  private var permissionCheck: ((String) -> Bool)?

  public init() {}

  /// Register a tool definition
  public func register(_ definition: MCPToolDefinition) {
    definitions.append(definition)
  }

  /// Register multiple tool definitions
  public func register(_ definitions: [MCPToolDefinition]) {
    self.definitions.append(contentsOf: definitions)
  }

  /// Register a tool handler
  public func register(handler: MCPToolHandling) {
    handlers.append(handler)
  }

  /// Set permission check callback
  public func setPermissionCheck(_ check: @escaping (String) -> Bool) {
    permissionCheck = check
  }

  /// Get all registered tool definitions
  public var allDefinitions: [MCPToolDefinition] {
    definitions
  }

  /// Get tool definition by name
  public func definition(named name: String) -> MCPToolDefinition? {
    definitions.first { $0.name == name }
  }

  /// Check if a tool is enabled
  public func isToolEnabled(_ name: String) -> Bool {
    permissionCheck?(name) ?? true
  }

  /// Find handler for a tool
  public func handler(for toolName: String) -> MCPToolHandling? {
    handlers.first { $0.supportedTools.contains(toolName) }
  }

  /// Build tools/list response
  public func toolList(sanitize: ((String) -> String)? = nil) -> [[String: Any]] {
    definitions.map { tool in
      let sanitizedName = sanitize?(tool.name) ?? tool.name
      return [
        "name": sanitizedName,
        "originalName": tool.name,
        "description": tool.description,
        "inputSchema": tool.inputSchema,
        "category": tool.category.rawValue,
        "enabled": isToolEnabled(tool.name),
        "requiresForeground": tool.requiresForeground
      ]
    }
  }
}
