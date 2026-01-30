//
//  MCPCore.swift
//  MCPCore
//
//  Core types and protocols for MCP automation framework.
//
//  This package provides:
//  - JSON-RPC 2.0 types for MCP communication
//  - Tool definitions and permissions
//  - Agent types, roles, and models
//  - Chain template definitions
//  - Data transfer objects for persistence
//  - CSQLite: Custom SQLite with extension loading support
//

import Foundation
@_exported import CSQLite  // Re-export CSQLite so importers get SQLite with extension support

// Re-export all public types
// (Swift automatically exports public types from the module)

// MARK: - Version

public enum MCPCoreVersion {
  public static let major = 0
  public static let minor = 1
  public static let patch = 0
  public static let string = "\(major).\(minor).\(patch)"
}
