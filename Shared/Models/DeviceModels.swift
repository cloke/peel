//
//  DeviceModels.swift
//  Peel
//
//  Device settings and onboarding SwiftData models (device-local).
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

/// App settings for THIS device only.
@Model
final class DeviceSettings {
  var id: UUID = UUID()
  var deviceName: String = "Unknown"
  var currentTool: String = "github"
  var selectedRepositoryId: UUID?
  var sidebarWidth: Double?
  var lastUsedAt: Date = Date()
  
  // Worktree auto-cleanup settings
  var worktreeRetentionDays: Int = 7
  var worktreeMaxDiskGB: Double = 10.0
  var worktreeAutoCleanup: Bool = true

  // Swarm auto-start: whether this device should automatically join the swarm on launch
  var swarmAutoStart: Bool = true

  // Swarm role to use on auto-start (persisted as SwarmRole.rawValue: "brain", "worker", "hybrid")
  var swarmRole: String = "hybrid"
  
  // Whether the swarm onboarding hint (first-run) has been shown to the user
  var swarmOnboardingShown: Bool = false
  
  @MainActor
  init() {
    self.id = UUID()
    #if os(macOS)
    self.deviceName = Host.current().localizedName ?? "Mac"
    #else
    self.deviceName = UIDevice.current.name
    #endif
    self.currentTool = "github"
    self.lastUsedAt = Date()
  }
  
  func touch() {
    lastUsedAt = Date()
  }
}

/// Tracks feature discovery checklist state (device-local, not synced to iCloud)
@Model
final class FeatureDiscoveryChecklist {
  var id: UUID = UUID()
  var isDismissed: Bool = false
  var didAddRepo: Bool = false
  var didRunChain: Bool = false
  var didIndexRAG: Bool = false
  var didConnectMCP: Bool = false
  var didJoinSwarm: Bool = false
  /// Bumped when new features are added; triggers checklist re-show for returning users
  var lastSeenFeatureVersion: Int = 0
  var createdAt: Date = Date()
  var updatedAt: Date = Date()

  init() {
    self.id = UUID()
    self.createdAt = Date()
    self.updatedAt = Date()
  }

  func touch() {
    updatedAt = Date()
  }
}
