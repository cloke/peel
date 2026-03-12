//
//  ConnectedPeer.swift
//  Peel
//
//  Represents a connected swarm peer with its capabilities.
//  Extracted from PeerConnectionManager.swift during TCP cleanup.
//

import Foundation

/// Represents a connected peer with its capabilities
public struct ConnectedPeer: Identifiable, Sendable {
  public let id: String
  public let name: String              // Raw hostname
  public let capabilities: WorkerCapabilities
  public let isIncoming: Bool  // true if they connected to us
  public let connectedAt: Date

  /// Friendly display name - uses custom name if configured, otherwise hostname
  public var displayName: String {
    capabilities.displayName ?? name
  }

  public init(id: String, name: String, capabilities: WorkerCapabilities, isIncoming: Bool) {
    self.id = id
    self.name = name
    self.capabilities = capabilities
    self.isIncoming = isIncoming
    self.connectedAt = Date()
  }
}
