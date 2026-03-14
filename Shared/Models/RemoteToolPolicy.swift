//
//  RemoteToolPolicy.swift
//  Peel
//
//  SwiftData model for per-peer remote MCP tool access control.
//  Default-deny: no tools are remotely callable until explicitly allowed.
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

/// Policy controlling which MCP tools a specific peer can invoke remotely.
/// Default-deny: peers must be explicitly granted access to each tool.
@Model
final class RemoteToolPolicy {
  var id: UUID = UUID()
  /// The peer's device ID this policy applies to
  var peerDeviceId: String = ""
  /// Human-readable peer name (for display)
  var peerDisplayName: String = ""
  /// Comma-separated list of allowed tool names (e.g. "rag.search,rag.status,swarm.status")
  /// Empty string = no tools allowed (default-deny)
  var allowedTools: String = ""
  /// Whether this policy is active (can be disabled without deleting)
  var isActive: Bool = true
  /// Maximum requests per minute from this peer (rate limiting)
  var maxRequestsPerMinute: Int = 60
  /// Whether sensitive tools (terminal.run, swarm.direct-command, file writes) require extra opt-in
  var allowSensitiveTools: Bool = false
  var createdAt: Date = Date()
  var updatedAt: Date = Date()

  init(
    peerDeviceId: String,
    peerDisplayName: String = "",
    allowedTools: String = "",
    maxRequestsPerMinute: Int = 60,
    allowSensitiveTools: Bool = false
  ) {
    self.id = UUID()
    self.peerDeviceId = peerDeviceId
    self.peerDisplayName = peerDisplayName
    self.allowedTools = allowedTools
    self.maxRequestsPerMinute = maxRequestsPerMinute
    self.allowSensitiveTools = allowSensitiveTools
    self.createdAt = Date()
    self.updatedAt = Date()
  }

  /// Tools that are considered sensitive and require explicit opt-in
  static let sensitiveTools: Set<String> = [
    "terminal.run",
    "swarm.direct-command",
    "code.edit",
    "code.edit_status",
    "parallel.create",
    "parallel.start",
  ]

  /// Check if a specific tool is allowed for this peer
  func isToolAllowed(_ toolName: String) -> Bool {
    guard isActive else { return false }
    let allowed = Set(allowedTools.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    // Check wildcard first
    if allowed.contains("*") {
      if Self.sensitiveTools.contains(toolName) {
        return allowSensitiveTools
      }
      return true
    }
    guard allowed.contains(toolName) else { return false }
    if Self.sensitiveTools.contains(toolName) && !allowSensitiveTools {
      return false
    }
    return true
  }
}
