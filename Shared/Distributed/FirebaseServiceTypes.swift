//
//  FirebaseServiceTypes.swift
//  Peel
//
//  Supporting types for FirebaseService — Firestore swarm coordination.
//  Extracted from FirebaseService.swift for improved organization.
//

import Foundation

// MARK: - Supporting Types

/// Swarm permission roles (distinct from SwarmRole which is brain/worker/hybrid)
///
/// These roles control what a user can do within a Firestore-coordinated swarm.
public enum SwarmPermissionRole: String, Sendable, Codable, CaseIterable {
  case owner = "owner"           // Level 4: Full control
  case admin = "admin"           // Level 3: Approve members, manage tasks
  case contributor = "contributor" // Level 2: Submit tasks, RAG read/write
  case reader = "reader"         // Level 1: Query RAG, view status
  case pending = "pending"       // Level 0: Awaiting approval
  
  public var level: Int {
    switch self {
    case .owner: return 4
    case .admin: return 3
    case .contributor: return 2
    case .reader: return 1
    case .pending: return 0
    }
  }
  
  public var canApproveMembers: Bool { level >= 3 }
  public var canSubmitTasks: Bool { level >= 2 }
  public var canQueryRAG: Bool { level >= 1 }
  public var canWriteRAG: Bool { level >= 2 }
  public var canRegisterWorkers: Bool { level >= 2 }
}

/// Basic swarm info
public struct SwarmInfo: Sendable, Identifiable, Hashable {
  public let id: String
  public let name: String
  public let ownerId: String
  public let memberCount: Int
  public let workerCount: Int
  public let created: Date
}

/// Swarm membership (user's relationship to a swarm)
public struct SwarmMembership: Sendable, Identifiable, Hashable {
  public let id: String  // swarmId
  public let swarmName: String
  public let role: SwarmPermissionRole
  public let joinedAt: Date
}

/// Swarm member info
public struct SwarmMember: Sendable, Identifiable, Hashable {
  public let id: String  // userId
  public let displayName: String
  public let email: String
  public let role: SwarmPermissionRole
  public let joinedAt: Date
  public let approvedBy: String?
}

/// Swarm invite
public struct SwarmInvite: Sendable {
  public let id: String
  public let url: URL
  public let qrCodeData: Data?
  public let expiresAt: Date
  public let maxUses: Int
  public let usedCount: Int
}

/// Detailed invite info for listing (#229)
public struct InviteDetails: Sendable, Identifiable {
  public let id: String
  public let swarmId: String
  public let token: String
  public let createdAt: Date
  public let expiresAt: Date
  public let maxUses: Int
  public let usedCount: Int
  public let usedBy: [String]
  public let createdBy: String
  public let isRevoked: Bool
  
  public var isExpired: Bool { expiresAt < Date() }
  public var isFullyUsed: Bool { usedCount >= maxUses }
  public var isValid: Bool { !isRevoked && !isExpired && !isFullyUsed }
}

/// Firebase service errors
public enum FirebaseError: LocalizedError {
  case notConfigured
  case notSignedIn
  case notImplemented
  case invalidInvite
  case inviteExpired
  case inviteRevoked
  case inviteFullyUsed
  case swarmNotFound
  case invalidCredential
  case permissionDenied
  case networkError(Error)
  
  public var errorDescription: String? {
    switch self {
    case .notConfigured: return "Firebase not configured"
    case .notSignedIn: return "Not signed in"
    case .notImplemented: return "Feature not yet implemented"
    case .invalidInvite: return "Invalid invite link"
    case .inviteExpired: return "This invite has expired"
    case .inviteRevoked: return "This invite has been revoked"
    case .inviteFullyUsed: return "This invite has reached its usage limit"
    case .swarmNotFound: return "Swarm not found"
    case .invalidCredential: return "Invalid Apple Sign-In credential"
    case .permissionDenied: return "Permission denied"
    case .networkError(let error): return "Network error: \(error.localizedDescription)"
    }
  }
}

/// Preview info for an invite before accepting (#237)
public struct InvitePreview: Sendable, Equatable {
  public let url: URL
  public let swarmId: String
  public let swarmName: String
  public let inviteId: String
  public let inviterName: String?
  public let expiresAt: Date
  public let remainingUses: Int
  public let isAlreadyMember: Bool
}

// MARK: - Firestore Worker Types (#225)

/// Type of swarm activity event for debugging
public enum SwarmActivityType: String, Sendable {
  // Worker events
  case workerRegistered = "worker_registered"
  case workerOnline = "worker_online"
  case workerOffline = "worker_offline"
  case workerHeartbeat = "heartbeat"
  
  // Task events
  case taskSubmitted = "task_submitted"
  case taskClaimed = "task_claimed"
  case taskCompleted = "task_completed"
  case taskFailed = "task_failed"
  
  // Message events
  case messageSent = "message_sent"
  case messageReceived = "message_received"
  
  // Connection events
  case swarmJoined = "swarm_joined"
  case swarmLeft = "swarm_left"
  case listenerStarted = "listener_started"
  case listenerStopped = "listener_stopped"
  
  // Errors
  case error = "error"
  
  /// Emoji for display
  public var emoji: String {
    switch self {
    case .workerRegistered: return "📝"
    case .workerOnline: return "🟢"
    case .workerOffline: return "🔴"
    case .workerHeartbeat: return "💓"
    case .taskSubmitted: return "📤"
    case .taskClaimed: return "🔒"
    case .taskCompleted: return "✅"
    case .taskFailed: return "❌"
    case .messageSent: return "📨"
    case .messageReceived: return "📬"
    case .swarmJoined: return "🐝"
    case .swarmLeft: return "👋"
    case .listenerStarted: return "👂"
    case .listenerStopped: return "🔇"
    case .error: return "⚠️"
    }
  }
}

/// A single swarm activity event for the debug log
public struct SwarmActivityEvent: Identifiable, Sendable {
  public let id = UUID()
  public let timestamp: Date
  public let type: SwarmActivityType
  public let message: String
  public let details: [String: String]?
  
  public init(type: SwarmActivityType, message: String, details: [String: Any]? = nil) {
    self.timestamp = Date()
    self.type = type
    self.message = message
    // Convert details to string representation
    if let details {
      var stringDetails: [String: String] = [:]
      for (key, value) in details {
        stringDetails[key] = String(describing: value)
      }
      self.details = stringDetails
    } else {
      self.details = nil
    }
  }
}

/// Status of a worker registered in Firestore
public enum FirestoreWorkerStatus: String, Sendable, Codable {
  case online
  case offline
  case busy
}

/// A message in a Firestore swarm
public struct SwarmMessage: Sendable, Identifiable, Equatable {
  public let id: String
  public let senderId: String
  public let senderDeviceId: String
  public let senderName: String
  public let text: String
  public let createdAt: Date
  public let isBroadcast: Bool
  public let targetWorkerId: String?
}

/// A worker registered in Firestore swarm
public struct FirestoreWorker: Sendable, Identifiable, Hashable {
  public let id: String  // workerId (device ID)
  public let ownerId: String  // userId who owns this worker
  public let displayName: String
  public let deviceName: String
  public let status: FirestoreWorkerStatus
  public let lastHeartbeat: Date
  public let version: String?

  /// LAN connection info (same network)
  public let lanAddress: String?
  public let lanPort: UInt16?

  /// WAN connection info for direct peer-to-peer connections
  public let wanAddress: String?
  public let wanPort: UInt16?
  
  /// STUN-discovered endpoint (NAT-mapped address:port for UDP hole punching)
  public let stunAddress: String?
  public let stunPort: UInt16?

  /// Convenience alias
  public var workerId: String { id }
  
  /// Whether the worker is considered stale (no heartbeat in 5 minutes).
  /// Firestore heartbeats fire every 30s; 5 min accommodates clock drift and
  /// transient connectivity without false-flagging active workers.
  public var isStale: Bool {
    Date().timeIntervalSince(lastHeartbeat) > 300
  }
  
  /// Whether this worker has valid WAN connection info
  public var hasWANEndpoint: Bool {
    wanAddress != nil && wanPort != nil
  }
  
  /// Whether this worker has a STUN-discovered endpoint for hole punching
  public var hasSTUNEndpoint: Bool {
    stunAddress != nil && stunPort != nil
  }
}

/// A task stored in Firestore for distributed execution
public struct FirestoreTask: Sendable, Identifiable, Hashable {
  public let id: String  // taskId (UUID string)
  public let templateName: String
  public let prompt: String
  public let status: ChainStatus
  public let createdBy: String
  public let createdAt: Date
  public let claimedBy: String?
  public let claimedByWorker: String?
}

/// Delegate protocol for task execution
/// Implement this to bridge Firestore tasks to your chain executor
@MainActor
public protocol FirestoreTaskExecutionDelegate: AnyObject {
  func executeTask(_ request: ChainRequest) async -> ChainResult
}
