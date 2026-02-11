//
//  FirebaseService.swift
//  Peel
//
//  Created for Firestore Swarm Integration
//  See Plans/FIRESTORE_SWARM_DESIGN.md
//

import Foundation
import os.log
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices
import CryptoKit

// MARK: - Firebase Service

/// Singleton service for Firebase integration (Firestore swarm coordination)
///
/// This service handles:
/// - Firebase initialization
/// - Apple Sign-In authentication
/// - Swarm membership management
/// - Real-time listeners for swarm state
///
/// **Setup Required:**
/// 1. Add Firebase SDK via Xcode: File → Add Package Dependencies
///    URL: https://github.com/firebase/firebase-ios-sdk
///    Products: FirebaseAuth, FirebaseFirestore, FirebaseFunctions, FirebaseAppCheck
/// 2. Add GoogleService-Info.plist to both targets
/// 3. Call `FirebaseService.shared.configure()` in PeelApp.init()
@MainActor
@Observable
public final class FirebaseService {
  
  // MARK: - Singleton
  
  public static let shared = FirebaseService()
  
  private let logger = Logger(subsystem: "com.peel.firebase", category: "FirebaseService")
  
  // MARK: - Activity Log (Debug)
  
  /// Activity log for debugging WAN events
  public private(set) var activityLog: [SwarmActivityEvent] = []
  
  /// Maximum activity log entries to keep
  private let maxActivityLogEntries = 100
  
  /// Log a swarm activity event
  public func logActivity(_ type: SwarmActivityType, message: String, details: [String: Any]? = nil) {
    let event = SwarmActivityEvent(type: type, message: message, details: details)
    activityLog.insert(event, at: 0)
    if activityLog.count > maxActivityLogEntries {
      activityLog.removeLast()
    }
  }
  
  /// Clear the activity log
  public func clearActivityLog() {
    activityLog.removeAll()
  }
  
  // MARK: - State
  
  /// Whether Firebase has been configured
  public private(set) var isConfigured = false
  
  /// Current user ID (from Firebase Auth)
  public private(set) var currentUserId: String?
  
  /// Current user email
  public private(set) var currentUserEmail: String?
  
  /// Current user display name
  public private(set) var currentUserDisplayName: String?
  
  /// Whether the user is signed in
  public var isSignedIn: Bool { currentUserId != nil }
  
  /// Swarms the current user belongs to
  public private(set) var memberSwarms: [SwarmMembership] = []
  
  /// Current active swarm (if any)
  public private(set) var activeSwarm: SwarmInfo?
  
  /// Our role in the active swarm
  public private(set) var activeSwarmPermission: SwarmPermissionRole = .pending
  
  /// Pending members awaiting approval (for admins)
  public private(set) var pendingMembers: [SwarmMember] = []
  
  /// All members of the current swarm (for admins/owners)
  public private(set) var swarmMembers: [SwarmMember] = []
  
  /// Registered workers across all active swarms (real-time, aggregated & deduplicated)
  public var swarmWorkers: [FirestoreWorker] {
    // Aggregate workers across all swarm listeners, deduplicating by worker ID
    // (a worker registered in multiple swarms appears once, preferring the most recent heartbeat)
    var seen: [String: FirestoreWorker] = [:]
    for (_, workers) in swarmWorkersBySwarmId {
      for worker in workers {
        if let existing = seen[worker.id] {
          if worker.lastHeartbeat > existing.lastHeartbeat {
            seen[worker.id] = worker
          }
        } else {
          seen[worker.id] = worker
        }
      }
    }
    return Array(seen.values)
  }

  /// Workers keyed by swarm ID (backing store for swarmWorkers)
  private var swarmWorkersBySwarmId: [String: [FirestoreWorker]] = [:]
  
  /// Pending tasks in the active swarm (real-time, for brain/dispatch)
  public private(set) var pendingTasks: [FirestoreTask] = []
  
  /// RAG artifacts in the active swarm (real-time)
  public private(set) var ragArtifacts: [FirestoreRAGArtifact] = []
  
  /// Current RAG artifact sync state (for progress UI)
  public private(set) var ragSyncState: FirestoreRAGSyncState?

  /// Recent messages in the swarm (real-time)
  public private(set) var swarmMessages: [SwarmMessage] = []

  /// Our registered worker ID (if we're acting as a worker)
  public private(set) var registeredWorkerId: String?

  /// Pending invite URL (stored when user is not signed in, processed after auth)
  public var pendingInviteURL: URL?
  
  /// Last deep link error message (for UI feedback)
  public private(set) var lastDeepLinkError: String?
  
  /// Flag to indicate deep link was received and needs UI attention
  public var deepLinkReceived = false
  
  /// ID of the swarm that was most recently joined (for UI auto-selection after invite)
  public var lastJoinedSwarmId: String?
  
  /// Pending invite preview (shown before accepting)
  public var pendingInvitePreview: InvitePreview?
  
  // MARK: - Private State
  
  private var authStateListener: AuthStateDidChangeListenerHandle?
  private var membershipListener: ListenerRegistration?
  private var membersListener: ListenerRegistration?
  private var invitesListener: ListenerRegistration?
  private var swarmListeners: [ListenerRegistration] = []
  private var workerListeners: [String: ListenerRegistration] = [:]  // keyed by swarmId
  private var messageListeners: [String: ListenerRegistration] = [:]  // keyed by swarmId
  private var taskListener: ListenerRegistration?
  private var heartbeatTask: Task<Void, Never>?
  private var currentNonce: String?
  
  // MARK: - Firestore References
  
  /// Lazily initialized Firestore instance - only access after isConfigured is true
  private var _db: Firestore?
  private var db: Firestore {
    if _db == nil {
      _db = Firestore.firestore()
    }
    return _db!
  }
  
  private func swarmsCollection() -> CollectionReference {
    db.collection("swarms")
  }
  
  private func membersCollection(swarmId: String) -> CollectionReference {
    db.collection("swarms/\(swarmId)/members")
  }
  
  private func invitesCollection(swarmId: String) -> CollectionReference {
    db.collection("swarms/\(swarmId)/invites")
  }
  
  private func workersCollection(swarmId: String) -> CollectionReference {
    db.collection("swarms/\(swarmId)/workers")
  }
  
  private func tasksCollection(swarmId: String) -> CollectionReference {
    db.collection("swarms/\(swarmId)/tasks")
  }
  
  private func ragArtifactsCollection(swarmId: String) -> CollectionReference {
    db.collection("swarms/\(swarmId)/ragArtifacts")
  }

  private func messagesCollection(swarmId: String) -> CollectionReference {
    db.collection("swarms/\(swarmId)/messages")
  }
  
  // MARK: - Initialization
  
  private init() {}
  
  // MARK: - Emulator Support
  
  /// Whether we're using Firebase emulators (local development)
  public private(set) var isUsingEmulators = false
  
  /// The emulator host (LAN IP or localhost)
  public private(set) var emulatorHost: String?
  
  /// Check if emulator mode is requested via environment or user defaults
  private var shouldUseEmulators: Bool {
    // Environment variable takes priority (set in Xcode scheme or launch script)
    if let envValue = ProcessInfo.processInfo.environment["FIREBASE_EMULATOR_HOST"] {
      return !envValue.isEmpty
    }
    // User defaults (settable from Settings UI)
    return UserDefaults.standard.bool(forKey: "firebase_use_emulators")
  }
  
  /// Resolve the emulator host address
  private var resolvedEmulatorHost: String {
    // Environment variable takes priority
    if let envHost = ProcessInfo.processInfo.environment["FIREBASE_EMULATOR_HOST"], !envHost.isEmpty {
      return envHost
    }
    // User defaults (e.g., "192.168.1.50" for LAN testing)
    if let host = UserDefaults.standard.string(forKey: "firebase_emulator_host"), !host.isEmpty {
      return host
    }
    return "localhost"
  }
  
  // MARK: - Configuration
  
  /// Configure Firebase. Call this in PeelApp.init()
  ///
  /// Set environment variable `FIREBASE_EMULATOR_HOST` to a LAN IP (e.g. "192.168.1.50")
  /// or "localhost" to use Firebase Emulator Suite instead of production.
  /// Both machines on the LAN can point at the same emulator host.
  public func configure() {
    guard !isConfigured else {
      logger.warning("Firebase already configured")
      return
    }
    
    FirebaseApp.configure()
    logger.info("Firebase configured successfully")
    
    // Configure Firestore settings before first use
    // Use memory-only cache to avoid persistence crashes
    let settings = FirestoreSettings()
    settings.cacheSettings = MemoryCacheSettings()
    
    // Connect to emulators if requested
    if shouldUseEmulators {
      let host = resolvedEmulatorHost
      emulatorHost = host
      isUsingEmulators = true
      
      // Firestore emulator (default port 8080)
      settings.host = "\(host):8080"
      settings.isSSLEnabled = false
      settings.cacheSettings = MemoryCacheSettings()
      logger.info("🔧 Firestore emulator: \(host):8080")
      
      // Auth emulator (default port 9099)
      Auth.auth().useEmulator(withHost: host, port: 9099)
      logger.info("🔧 Auth emulator: \(host):9099")
      
      logger.warning("⚠️ Firebase running against LOCAL EMULATORS — not production")
    }
    
    Firestore.firestore().settings = settings
    _db = Firestore.firestore()
    
    isConfigured = true
    
    setupAuthStateListener()
  }
  
  private func setupAuthStateListener() {
    authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
      Task { @MainActor in
        self?.handleAuthStateChange(user: user)
      }
    }
  }
  
  private func handleAuthStateChange(user: User?) {
    if let user = user {
      currentUserId = user.uid
      currentUserEmail = user.email
      // Apple Sign-In only provides displayName on FIRST auth.
      // Cache it so subsequent sign-ins still have it.
      if let name = user.displayName, !name.isEmpty {
        currentUserDisplayName = name
        UserDefaults.standard.set(name, forKey: "peel.cachedDisplayName.\(user.uid)")
      } else {
        // Fall back to: cached name → worker config name → device name
        currentUserDisplayName = UserDefaults.standard.string(forKey: "peel.cachedDisplayName.\(user.uid)")
          ?? WorkerCapabilities.current().displayName
          ?? ProcessInfo.processInfo.hostName
      }
      logger.info("User signed in: \(user.uid)")
      Task {
        await loadUserSwarms()
        startMembershipListener(userId: user.uid)
        // Process any pending invite that was received before sign-in
        await processPendingInvite()
      }
    } else {
      currentUserId = nil
      currentUserEmail = nil
      currentUserDisplayName = nil
      memberSwarms = []
      activeSwarm = nil
      stopMembershipListener()
      removeSwarmListeners()
      logger.info("User signed out")
    }
  }
  
  // MARK: - Authentication
  
  /// Sign in with Apple - returns the credential for ASAuthorizationController
  public func prepareAppleSignIn() -> (request: ASAuthorizationAppleIDRequest, nonce: String) {
    let nonce = randomNonceString()
    currentNonce = nonce
    
    let appleIDProvider = ASAuthorizationAppleIDProvider()
    let request = appleIDProvider.createRequest()
    request.requestedScopes = [.fullName, .email]
    request.nonce = sha256(nonce)
    
    return (request, nonce)
  }
  
  /// Complete Apple Sign-In with the authorization result
  public func completeAppleSignIn(authorization: ASAuthorization) async throws {
    guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
          let nonce = currentNonce,
          let appleIDToken = appleIDCredential.identityToken,
          let idTokenString = String(data: appleIDToken, encoding: .utf8)
    else {
      throw FirebaseError.invalidCredential
    }
    
    let credential = OAuthProvider.appleCredential(
      withIDToken: idTokenString,
      rawNonce: nonce,
      fullName: appleIDCredential.fullName
    )
    
    let result = try await Auth.auth().signIn(with: credential)
    logger.info("Successfully signed in with Apple: \(result.user.uid)")
    
    // Apple only provides fullName on FIRST sign-in. Cache it eagerly so
    // subsequent auth state changes (which will have nil displayName) can recover it.
    if let fullName = appleIDCredential.fullName {
      let formatted = PersonNameComponentsFormatter.localizedString(from: fullName, style: .default)
      if !formatted.isEmpty {
        UserDefaults.standard.set(formatted, forKey: "peel.cachedDisplayName.\(result.user.uid)")
      }
    }
    
    currentNonce = nil
  }
  
  /// Sign out
  public func signOut() throws {
    logger.info("Signing out")
    try Auth.auth().signOut()
    currentUserId = nil
    currentUserEmail = nil
    currentUserDisplayName = nil
    memberSwarms = []
    activeSwarm = nil
    removeSwarmListeners()
  }
  
  // MARK: - Swarm Operations
  
  /// Load swarms the user belongs to
  private func loadUserSwarms() async {
    guard isConfigured else {
      logger.warning("Firebase not configured, skipping swarm load")
      return
    }
    guard let userId = currentUserId else {
      logger.warning("No current user ID, skipping swarm load")
      return
    }
    
    logger.info("Loading swarms for user: \(userId)")
    
    do {
      var swarms: [SwarmMembership] = []
      var seenSwarmIds = Set<String>()
      
      // 1. Get swarms where user is owner
      let ownedSwarms = try await swarmsCollection()
        .whereField("ownerId", isEqualTo: userId)
        .getDocuments()
      
      logger.info("Found \(ownedSwarms.documents.count) owned swarms")
      
      for swarmDoc in ownedSwarms.documents {
        let swarmId = swarmDoc.documentID
        let swarmData = swarmDoc.data()
        let swarmName = swarmData["name"] as? String ?? "Unknown"
        
        // Get membership doc for joined date
        let memberDoc = try? await membersCollection(swarmId: swarmId)
          .document(userId)
          .getDocument()
        let joinedAt = (memberDoc?.data()?["joinedAt"] as? Timestamp)?.dateValue() ?? Date()
        
        swarms.append(SwarmMembership(
          id: swarmId,
          swarmName: swarmName,
          role: .owner,
          joinedAt: joinedAt
        ))
        seenSwarmIds.insert(swarmId)
      }
      
      // 2. Get swarms where user is a member (via collection group query)
      // This requires "members" collection group to be indexed in Firestore
      do {
        let memberDocs = try await db.collectionGroup("members")
          .whereField("userId", isEqualTo: userId)
          .getDocuments()
        
        logger.info("Found \(memberDocs.documents.count) memberships via collection group")
        
        for memberDoc in memberDocs.documents {
          // Extract swarm ID from path: swarms/{swarmId}/members/{userId}
          let pathComponents = memberDoc.reference.path.split(separator: "/")
          guard pathComponents.count >= 2,
                let swarmIdIndex = pathComponents.firstIndex(of: "swarms"),
                swarmIdIndex + 1 < pathComponents.count else {
            continue
        }
        let swarmId = String(pathComponents[swarmIdIndex + 1])
        
        // Skip if we already have this swarm (from owner query)
        guard !seenSwarmIds.contains(swarmId) else { continue }
        seenSwarmIds.insert(swarmId)
        
        let memberData = memberDoc.data()
        let roleString = memberData["role"] as? String ?? "reader"
        let role: SwarmPermissionRole = SwarmPermissionRole(rawValue: roleString) ?? .reader
        let joinedAt = (memberData["joinedAt"] as? Timestamp)?.dateValue() ?? Date()
        
        // Fetch swarm name
        let swarmDoc = try? await swarmsCollection().document(swarmId).getDocument()
        let swarmName = swarmDoc?.data()?["name"] as? String ?? "Unknown Swarm"
        
        swarms.append(SwarmMembership(
          id: swarmId,
          swarmName: swarmName,
          role: role,
          joinedAt: joinedAt
        ))
        }
      } catch {
        logger.warning("Collection group query failed (index may be building): \(error)")
      }
      
      memberSwarms = swarms
      logger.info("Loaded \(swarms.count) swarm memberships")
    } catch {
      logger.error("Failed to load swarms: \(error)")
    }
  }
  
  /// Debug: Return current state info (no async queries to avoid threading issues)
  public func debugQuerySwarms() -> [String: Any] {
    return [
      "userId": currentUserId ?? "nil",
      "email": currentUserEmail ?? "nil",
      "displayName": currentUserDisplayName ?? "nil",
      "isSignedIn": isSignedIn,
      "isConfigured": isConfigured,
      "memberSwarmCount": memberSwarms.count,
      "memberSwarms": memberSwarms.map { [
        "id": $0.id,
        "name": $0.swarmName,
        "role": $0.role.rawValue
      ] }
    ]
  }
  
  /// Migration: Add userId field to all member documents that don't have it
  /// This is needed for collection group queries to find user memberships
  public func migrateMemberUserIds() async throws -> [String: Any] {
    guard isConfigured else { throw FirebaseError.notConfigured }
    guard isSignedIn else { throw FirebaseError.notSignedIn }
    
    var results: [[String: Any]] = []
    
    // Get all swarms
    let swarmsSnapshot = try await swarmsCollection().getDocuments()
    
    for swarmDoc in swarmsSnapshot.documents {
      let swarmId = swarmDoc.documentID
      let swarmName = swarmDoc.data()["name"] as? String ?? "Unknown"
      
      // Get members of this swarm
      let membersSnapshot = try await membersCollection(swarmId: swarmId).getDocuments()
      
      for memberDoc in membersSnapshot.documents {
        let memberId = memberDoc.documentID
        let data = memberDoc.data()
        let displayName = data["displayName"] as? String ?? data["email"] as? String ?? memberId
        let hasUserId = data["userId"] != nil
        
        var memberResult: [String: Any] = [
          "swarmId": swarmId,
          "swarmName": swarmName,
          "memberId": memberId,
          "displayName": displayName,
          "hadUserId": hasUserId
        ]
        
        if !hasUserId {
          // Add userId field
          try await membersCollection(swarmId: swarmId).document(memberId).updateData([
            "userId": memberId
          ])
          memberResult["updated"] = true
          logger.info("Added userId to member \(displayName) in swarm \(swarmName)")
        } else {
          memberResult["updated"] = false
        }
        
        results.append(memberResult)
      }
    }
    
    return [
      "swarmsProcessed": swarmsSnapshot.documents.count,
      "membersProcessed": results.count,
      "membersUpdated": results.filter { $0["updated"] as? Bool == true }.count,
      "details": results
    ]
  }

  /// Export all swarm data for backup
  public func exportSwarmData() async throws -> [String: Any] {
    guard isConfigured else { throw FirebaseError.notConfigured }
    guard isSignedIn else { throw FirebaseError.notSignedIn }

    var swarmsData: [[String: Any]] = []

    // Get all swarms the user owns
    let ownedSwarms = try await swarmsCollection()
      .whereField("ownerId", isEqualTo: currentUserId ?? "")
      .getDocuments()

    for swarmDoc in ownedSwarms.documents {
      let swarmId = swarmDoc.documentID
      var swarmData = swarmDoc.data()
      swarmData["id"] = swarmId

      // Get members
      let membersSnapshot = try await membersCollection(swarmId: swarmId).getDocuments()
      let members = membersSnapshot.documents.map { doc -> [String: Any] in
        var data = doc.data()
        data["id"] = doc.documentID
        return data
      }
      swarmData["members"] = members

      // Get invites
      let invitesSnapshot = try await invitesCollection(swarmId: swarmId).getDocuments()
      let invites = invitesSnapshot.documents.map { doc -> [String: Any] in
        var data = doc.data()
        data["id"] = doc.documentID
        return data
      }
      swarmData["invites"] = invites

      swarmsData.append(swarmData)
    }

    // Also get swarms where user is a member (but not owner)
    let memberSwarms = try await swarmsCollection().getDocuments()
    for swarmDoc in memberSwarms.documents {
      let swarmId = swarmDoc.documentID
      let ownerId = swarmDoc.data()["ownerId"] as? String ?? ""

      // Skip if we already added this as owner
      if ownerId == currentUserId { continue }

      // Check if user is a member
      let membersSnapshot = try await membersCollection(swarmId: swarmId)
        .whereField("userId", isEqualTo: currentUserId ?? "")
        .getDocuments()

      if !membersSnapshot.documents.isEmpty {
        var swarmData = swarmDoc.data()
        swarmData["id"] = swarmId
        swarmData["_memberOnly"] = true  // Mark that we're just a member

        // Get all members for context
        let allMembersSnapshot = try await membersCollection(swarmId: swarmId).getDocuments()
        let members = allMembersSnapshot.documents.map { doc -> [String: Any] in
          var data = doc.data()
          data["id"] = doc.documentID
          return data
        }
        swarmData["members"] = members

        swarmsData.append(swarmData)
      }
    }

    return [
      "exportedAt": ISO8601DateFormatter().string(from: Date()),
      "exportedBy": currentUserId ?? "unknown",
      "swarms": swarmsData
    ]
  }
  
  /// Create a new swarm
  public func createSwarm(name: String) async throws -> String {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    logger.info("Creating swarm: \(name)")
    
    let swarmRef = swarmsCollection().document()
    let swarmId = swarmRef.documentID
    
    let batch = db.batch()
    
    // Create swarm document
    batch.setData([
      "ownerId": userId,
      "name": name,
      "created": FieldValue.serverTimestamp(),
      "settings": [
        "maxWorkers": 10,
        "requireApproval": true
      ]
    ], forDocument: swarmRef)
    
    // Create owner membership (include ownerId for collection group queries)
    batch.setData([
      "userId": userId,
      "displayName": currentUserDisplayName ?? WorkerCapabilities.current().displayName ?? ProcessInfo.processInfo.hostName,
      "email": currentUserEmail ?? "",
      "joinedAt": FieldValue.serverTimestamp(),
      "role": "owner",
      "roleLevel": 4,
      "status": "active"
    ], forDocument: membersCollection(swarmId: swarmId).document(userId))
    
    try await batch.commit()
    logger.info("Created swarm: \(swarmId)")
    
    // Log activity
    logActivity(.swarmJoined, message: "Created swarm: \(name)", details: [
      "swarmId": swarmId,
      "role": "owner"
    ])
    
    // Reload swarms
    await loadUserSwarms()
    
    return swarmId
  }
  
  /// Generate an invite for a swarm
  public func createInvite(
    swarmId: String,
    expiresIn: TimeInterval = 86400,
    maxUses: Int = 1
  ) async throws -> SwarmInvite {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission to create invites (admin+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 3 else {
      throw FirebaseError.permissionDenied
    }
    
    let token = generateSecureToken()
    let inviteRef = invitesCollection(swarmId: swarmId).document()
    let expiresAt = Date().addingTimeInterval(expiresIn)
    
    try await inviteRef.setData([
      "token": token,
      "created": FieldValue.serverTimestamp(),
      "expires": Timestamp(date: expiresAt),
      "maxUses": maxUses,
      "usedBy": [],
      "createdBy": userId,
      "revoked": false
    ])
    
    let urlString = "peel://swarm/join?s=\(swarmId)&i=\(inviteRef.documentID)&t=\(token)"
    guard let url = URL(string: urlString) else {
      throw FirebaseError.invalidInvite
    }
    
    logger.info("Created invite for swarm \(swarmId)")
    
    return SwarmInvite(
      id: inviteRef.documentID,
      url: url,
      qrCodeData: nil, // QR code generation can be added later
      expiresAt: expiresAt,
      maxUses: maxUses,
      usedCount: 0
    )
  }
  
  /// Load all invites for a swarm (admin+ only) (#229)
  public func loadInvites(swarmId: String) async throws -> [InviteDetails] {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission (admin+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 3 else {
      throw FirebaseError.permissionDenied
    }
    
    let snapshot = try await invitesCollection(swarmId: swarmId)
      .order(by: "created", descending: true)
      .limit(to: 50)
      .getDocuments()
    
    return snapshot.documents.compactMap { doc -> InviteDetails? in
      let data = doc.data()
      guard let token = data["token"] as? String,
            let expires = data["expires"] as? Timestamp,
            let maxUses = data["maxUses"] as? Int,
            let usedBy = data["usedBy"] as? [String],
            let revoked = data["revoked"] as? Bool
      else { return nil }
      
      let created = (data["created"] as? Timestamp)?.dateValue() ?? Date()
      let createdBy = data["createdBy"] as? String ?? "unknown"
      
      return InviteDetails(
        id: doc.documentID,
        swarmId: swarmId,
        token: token,
        createdAt: created,
        expiresAt: expires.dateValue(),
        maxUses: maxUses,
        usedCount: usedBy.count,
        usedBy: usedBy,
        createdBy: createdBy,
        isRevoked: revoked
      )
    }
  }
  
  /// Revoke an invite
  public func revokeInvite(swarmId: String, inviteId: String) async throws {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission (admin+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 3 else {
      throw FirebaseError.permissionDenied
    }
    
    try await invitesCollection(swarmId: swarmId).document(inviteId).updateData([
      "revoked": true
    ])
    
    logger.info("Revoked invite \(inviteId)")
  }
  
  /// Fetch invite preview details without accepting (#237)
  public func fetchInvitePreview(url: URL) async throws -> InvitePreview {
    guard isConfigured else { throw FirebaseError.notConfigured }
    
    // Parse URL
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let swarmId = components.queryItems?.first(where: { $0.name == "s" })?.value,
          let inviteId = components.queryItems?.first(where: { $0.name == "i" })?.value,
          let token = components.queryItems?.first(where: { $0.name == "t" })?.value
    else {
      throw FirebaseError.invalidInvite
    }
    
    // Get swarm info
    let swarmDoc = try await swarmsCollection().document(swarmId).getDocument()
    guard let swarmData = swarmDoc.data(),
          let swarmName = swarmData["name"] as? String
    else {
      throw FirebaseError.swarmNotFound
    }
    
    // Get invite info
    let inviteDoc = try await invitesCollection(swarmId: swarmId).document(inviteId).getDocument()
    guard let inviteData = inviteDoc.data(),
          let storedToken = inviteData["token"] as? String,
          storedToken == token
    else {
      throw FirebaseError.invalidInvite
    }
    
    // Check if revoked
    if let revoked = inviteData["revoked"] as? Bool, revoked {
      throw FirebaseError.inviteRevoked
    }
    
    // Check expiration
    guard let expires = inviteData["expires"] as? Timestamp else {
      throw FirebaseError.invalidInvite
    }
    let expiresAt = expires.dateValue()
    if expiresAt < Date() {
      throw FirebaseError.inviteExpired
    }
    
    // Check uses
    let maxUses = inviteData["maxUses"] as? Int ?? 1
    let usedBy = inviteData["usedBy"] as? [String] ?? []
    if usedBy.count >= maxUses {
      throw FirebaseError.inviteFullyUsed
    }
    
    // Get inviter info
    let createdBy = inviteData["createdBy"] as? String
    var inviterName: String?
    if let inviterId = createdBy {
      let inviterDoc = try? await membersCollection(swarmId: swarmId).document(inviterId).getDocument()
      inviterName = inviterDoc?.data()?["displayName"] as? String
    }
    
    // Check if already a member
    var isAlreadyMember = false
    if let userId = currentUserId {
      let memberDoc = try? await membersCollection(swarmId: swarmId).document(userId).getDocument()
      isAlreadyMember = memberDoc?.exists == true
    }
    
    return InvitePreview(
      url: url,
      swarmId: swarmId,
      swarmName: swarmName,
      inviteId: inviteId,
      inviterName: inviterName,
      expiresAt: expiresAt,
      remainingUses: maxUses - usedBy.count,
      isAlreadyMember: isAlreadyMember
    )
  }
  
  /// Accept a swarm invite
  public func acceptInvite(url: URL) async throws {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Parse URL
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let swarmId = components.queryItems?.first(where: { $0.name == "s" })?.value,
          let inviteId = components.queryItems?.first(where: { $0.name == "i" })?.value,
          let token = components.queryItems?.first(where: { $0.name == "t" })?.value
    else {
      throw FirebaseError.invalidInvite
    }
    
    logger.info("Accepting invite to swarm \(swarmId)")
    
    // Get and validate invite
    let inviteRef = invitesCollection(swarmId: swarmId).document(inviteId)
    let inviteDoc = try await inviteRef.getDocument()
    
    guard let inviteData = inviteDoc.data(),
          let storedToken = inviteData["token"] as? String,
          storedToken == token,
          let revoked = inviteData["revoked"] as? Bool, !revoked,
          let expires = inviteData["expires"] as? Timestamp,
          expires.dateValue() > Date(),
          let maxUses = inviteData["maxUses"] as? Int,
          let usedBy = inviteData["usedBy"] as? [String],
          usedBy.count < maxUses
    else {
      throw FirebaseError.invalidInvite
    }
    
    let batch = db.batch()
    
    // Add user as pending member (include userId for collection group queries)
    batch.setData([
      "userId": userId,
      "displayName": currentUserDisplayName ?? WorkerCapabilities.current().displayName ?? ProcessInfo.processInfo.hostName,
      "email": currentUserEmail ?? "",
      "joinedAt": FieldValue.serverTimestamp(),
      "invitedBy": inviteData["createdBy"] as? String ?? "",
      "role": "pending",
      "roleLevel": 0,
      "status": "active",
      "approvedBy": NSNull(),
      "approvedAt": NSNull()
    ], forDocument: membersCollection(swarmId: swarmId).document(userId))
    
    // Update invite usage
    batch.updateData([
      "usedBy": FieldValue.arrayUnion([userId])
    ], forDocument: inviteRef)
    
    try await batch.commit()
    logger.info("Successfully joined swarm \(swarmId) as pending member")
    
    // Log activity
    logActivity(.swarmJoined, message: "Joined swarm as pending member", details: [
      "swarmId": swarmId,
      "role": "pending"
    ])
    
    // Store the joined swarm ID for UI auto-selection (#236)
    lastJoinedSwarmId = swarmId
    
    // Reload swarms
    await loadUserSwarms()
  }
  
  /// Approve a pending member (admin/owner only)
  public func approveMember(
    swarmId: String,
    userId: String,
    role: SwarmPermissionRole = .contributor
  ) async throws {
    guard let myUserId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify caller has permission (admin+)
    let myMemberDoc = try await membersCollection(swarmId: swarmId).document(myUserId).getDocument()
    guard let myRoleLevel = myMemberDoc.data()?["roleLevel"] as? Int, myRoleLevel >= 3 else {
      throw FirebaseError.permissionDenied
    }
    
    // Can't promote higher than own level (except owner can do anything)
    if myRoleLevel < 4 && role.level >= myRoleLevel {
      throw FirebaseError.permissionDenied
    }
    
    try await membersCollection(swarmId: swarmId).document(userId).updateData([
      "role": role.rawValue,
      "roleLevel": role.level,
      "approvedBy": myUserId,
      "approvedAt": FieldValue.serverTimestamp()
    ])
    
    logger.info("Approved member \(userId) as \(role.rawValue)")
  }
  
  /// Revoke a member's access
  public func revokeMember(swarmId: String, userId: String) async throws {
    guard let myUserId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify caller has permission (admin+)
    let myMemberDoc = try await membersCollection(swarmId: swarmId).document(myUserId).getDocument()
    guard let myRoleLevel = myMemberDoc.data()?["roleLevel"] as? Int, myRoleLevel >= 3 else {
      throw FirebaseError.permissionDenied
    }
    
    // Can't revoke someone with same or higher role (unless owner)
    let targetMemberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    if let targetRoleLevel = targetMemberDoc.data()?["roleLevel"] as? Int,
       targetRoleLevel >= myRoleLevel && myRoleLevel < 4 {
      throw FirebaseError.permissionDenied
    }
    
    try await membersCollection(swarmId: swarmId).document(userId).updateData([
      "status": "revoked",
      "revokedAt": FieldValue.serverTimestamp(),
      "revokedBy": myUserId
    ])
    
    logger.info("Revoked member \(userId)")
  }
  
  /// Load pending members for a swarm (admin+ only)
  public func loadPendingMembers(swarmId: String) async throws {
    guard let myUserId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify caller has permission
    let myMemberDoc = try await membersCollection(swarmId: swarmId).document(myUserId).getDocument()
    guard let myRoleLevel = myMemberDoc.data()?["roleLevel"] as? Int, myRoleLevel >= 3 else {
      throw FirebaseError.permissionDenied
    }
    
    let snapshot = try await membersCollection(swarmId: swarmId)
      .whereField("role", isEqualTo: "pending")
      .getDocuments()
    
    let members = snapshot.documents.compactMap { doc -> SwarmMember? in
      let data = doc.data()
      guard let roleString = data["role"] as? String,
            let role = SwarmPermissionRole(rawValue: roleString)
      else { return nil }
      
      return SwarmMember(
        id: doc.documentID,
        displayName: data["displayName"] as? String ?? "Unknown",
        email: data["email"] as? String ?? "",
        role: role,
        joinedAt: (data["joinedAt"] as? Timestamp)?.dateValue() ?? Date(),
        approvedBy: data["approvedBy"] as? String
      )
    }
    
    pendingMembers = members
    logger.info("Loaded \(members.count) pending members")
  }
  
  /// Load all members of a swarm (not just pending)
  public func loadSwarmMembers(swarmId: String) async throws {
    let snapshot = try await membersCollection(swarmId: swarmId)
      .whereField("role", isNotEqualTo: "pending")
      .getDocuments()
    
    let members = snapshot.documents.compactMap { doc -> SwarmMember? in
      let data = doc.data()
      guard let roleString = data["role"] as? String,
            let role = SwarmPermissionRole(rawValue: roleString)
      else { return nil }
      
      return SwarmMember(
        id: doc.documentID,
        displayName: data["displayName"] as? String ?? "Unknown",
        email: data["email"] as? String ?? "",
        role: role,
        joinedAt: (data["joinedAt"] as? Timestamp)?.dateValue() ?? Date(),
        approvedBy: data["approvedBy"] as? String
      )
    }.sorted { $0.role.level > $1.role.level } // Sort by role level (owner first)
    
    swarmMembers = members
    logger.info("Loaded \(members.count) swarm members")
  }
  
  // MARK: - Worker Management (#225)
  
  /// Register this device as a worker in a swarm
  public func registerWorker(
    swarmId: String,
    capabilities: WorkerCapabilities
  ) async throws -> String {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission (contributor+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 2 else {
      throw FirebaseError.permissionDenied
    }
    
    let workerId = capabilities.deviceId
    let workerRef = workersCollection(swarmId: swarmId).document(workerId)
    
    // Build worker data with optional LAN endpoint
    var workerData: [String: Any] = [
      "ownerId": userId,
      "displayName": capabilities.displayName ?? capabilities.deviceName,
      "deviceName": capabilities.deviceName,
      "capabilities": [
        "platform": capabilities.platform.rawValue,
        "gpuCores": capabilities.gpuCores,
        "neuralEngineCores": capabilities.neuralEngineCores,
        "memoryGB": capabilities.memoryGB,
        "storageAvailableGB": capabilities.storageAvailableGB,
        "embeddingModel": capabilities.embeddingModel as Any,
        "embeddingDimensions": capabilities.embeddingDimensions as Any,
        "indexedRepos": capabilities.indexedRepos
      ],
      "status": "online",
      "lastHeartbeat": FieldValue.serverTimestamp(),
      "version": capabilities.gitCommitHash ?? "unknown",
      "registeredAt": FieldValue.serverTimestamp()
    ]
    
    // Add LAN endpoint if provided
    if let lanAddress = capabilities.lanAddress {
      workerData["lanAddress"] = lanAddress
      workerData["lanPort"] = Int(capabilities.lanPort ?? 8766)
    }
    
    // Add WAN endpoint if provided (enables P2P connections across networks)
    if let wanAddress = capabilities.wanAddress {
      workerData["wanAddress"] = wanAddress
      workerData["wanPort"] = Int(capabilities.wanPort ?? 8766)
    }
    
    // Add STUN-discovered endpoint (NAT-mapped address:port for UDP hole punching)
    if let stunAddress = capabilities.stunAddress {
      workerData["stunAddress"] = stunAddress
      workerData["stunPort"] = Int(capabilities.stunPort ?? 8766)
    }
    
    try await workerRef.setData(workerData)
    
    registeredWorkerId = workerId
    logger.info("Registered worker \(workerId) in swarm \(swarmId)")
    
    // Log registration
    logActivity(.workerRegistered, message: "Registered as worker", details: [
      "workerId": workerId,
      "swarmId": swarmId,
      "device": capabilities.deviceName
    ])
    
    // Start heartbeat loop
    startHeartbeatLoop(swarmId: swarmId, workerId: workerId)
    
    // Start listening for task assignments
    startTaskListener(swarmId: swarmId, workerId: workerId)
    
    return workerId
  }
  
  /// Update a worker's STUN-discovered endpoint in Firestore.
  /// Called after STUN discovery completes (may be asynchronous from registration).
  public func updateWorkerSTUNEndpoint(
    swarmId: String,
    workerId: String,
    stunAddress: String,
    stunPort: UInt16
  ) async throws {
    try await workersCollection(swarmId: swarmId).document(workerId).updateData([
      "stunAddress": stunAddress,
      "stunPort": Int(stunPort)
    ])
    logger.info("Updated STUN endpoint for worker \(workerId): \(stunAddress):\(stunPort)")
  }
  
  /// Unregister this device as a worker
  public func unregisterWorker(swarmId: String) async throws {
    guard let workerId = registeredWorkerId else { return }
    
    stopHeartbeatLoop()
    stopTaskListener()
    
    try await workersCollection(swarmId: swarmId).document(workerId).updateData([
      "status": "offline",
      "lastHeartbeat": FieldValue.serverTimestamp()
    ])
    
    logActivity(.workerOffline, message: "Unregistered from swarm", details: [
      "workerId": workerId,
      "swarmId": swarmId
    ])
    
    registeredWorkerId = nil
    logger.info("Unregistered worker \(workerId)")
  }
  
  /// Send heartbeat to update worker status
  private func sendHeartbeat(swarmId: String, workerId: String, status: String = "online") async {
    do {
      try await workersCollection(swarmId: swarmId).document(workerId).updateData([
        "status": status,
        "lastHeartbeat": FieldValue.serverTimestamp()
      ])
    } catch {
      logger.error("Failed to send heartbeat: \(error)")
    }
  }
  
  private func startHeartbeatLoop(swarmId: String, workerId: String) {
    stopHeartbeatLoop()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sendHeartbeat(swarmId: swarmId, workerId: workerId)
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }
  
  private func stopHeartbeatLoop() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }
  
  /// Start listening for workers in a swarm (for brain/dashboard)
  public func startWorkerListener(swarmId: String) {
    // Deduplicate — skip if already listening for this swarm
    if workerListeners[swarmId] != nil {
      logger.debug("Worker listener already active for swarm \(swarmId)")
      return
    }

    logActivity(.listenerStarted, message: "Workers listener started", details: ["swarmId": swarmId])
    
    let listener = workersCollection(swarmId: swarmId)
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self, let snapshot = snapshot else {
          if let error = error {
            self?.logger.error("Worker listener error: \(error)")
            Task { @MainActor in
              self?.logActivity(.error, message: "Worker listener error", details: ["error": error.localizedDescription])
            }
          }
          return
        }
        
        Task { @MainActor in
          let previousWorkers = Set((self.swarmWorkersBySwarmId[swarmId] ?? []).map { $0.id })
          
          let newWorkers = snapshot.documents.compactMap { doc -> FirestoreWorker? in
            let data = doc.data()
            return FirestoreWorker(
              id: doc.documentID,
              ownerId: data["ownerId"] as? String ?? "",
              displayName: data["displayName"] as? String ?? "Unknown",
              deviceName: data["deviceName"] as? String ?? "",
              status: FirestoreWorkerStatus(rawValue: data["status"] as? String ?? "offline") ?? .offline,
              lastHeartbeat: (data["lastHeartbeat"] as? Timestamp)?.dateValue() ?? Date.distantPast,
              version: data["version"] as? String,
              wanAddress: data["wanAddress"] as? String,
              wanPort: (data["wanPort"] as? Int).map { UInt16($0) },
              stunAddress: data["stunAddress"] as? String,
              stunPort: (data["stunPort"] as? Int).map { UInt16($0) }
            )
          }
          
          // Log worker changes
          for worker in newWorkers {
            if !previousWorkers.contains(worker.id) {
              self.logActivity(.workerOnline, message: "\(worker.displayName) joined", details: [
                "workerId": worker.id,
                "device": worker.deviceName
              ])
            }
          }
          
          let newWorkerIds = Set(newWorkers.map { $0.id })
          let previousSwarmWorkers = self.swarmWorkersBySwarmId[swarmId] ?? []
          for worker in previousSwarmWorkers where !newWorkerIds.contains(worker.id) {
            self.logActivity(.workerOffline, message: "\(worker.displayName) left", details: [
              "workerId": worker.id
            ])
          }
          
          self.swarmWorkersBySwarmId[swarmId] = newWorkers
        }
      }
    workerListeners[swarmId] = listener
  }
  
  /// Stop worker listener for a specific swarm
  public func stopWorkerListener(swarmId: String) {
    if let listener = workerListeners.removeValue(forKey: swarmId) {
      listener.remove()
      swarmWorkersBySwarmId.removeValue(forKey: swarmId)
      logActivity(.listenerStopped, message: "Worker listener stopped for swarm", details: ["swarmId": swarmId])
    }
  }
  
  private func stopWorkerListeners() {
    if !workerListeners.isEmpty {
      logActivity(.listenerStopped, message: "Worker listeners stopped", details: [
        "count": String(workerListeners.count)
      ])
    }
    for (_, listener) in workerListeners {
      listener.remove()
    }
    workerListeners.removeAll()
    swarmWorkersBySwarmId.removeAll()
  }
  
  // MARK: - Messages

  /// Send a message to a specific worker or broadcast to all workers in a swarm
  public func sendMessage(swarmId: String, text: String, targetWorkerId: String? = nil) async throws {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    let caps = WorkerCapabilities.current()
    let displayName = currentUserDisplayName
      ?? caps.displayName
      ?? caps.deviceName
    let deviceId = caps.deviceId

    var data: [String: Any] = [
      "senderId": userId,
      "senderDeviceId": deviceId,
      "senderName": displayName,
      "text": text,
      "createdAt": FieldValue.serverTimestamp(),
      "isBroadcast": targetWorkerId == nil
    ]
    if let targetWorkerId {
      data["targetWorkerId"] = targetWorkerId
    }

    try await messagesCollection(swarmId: swarmId).addDocument(data: data)

    logActivity(.messageSent, message: targetWorkerId == nil ? "Broadcast: \(text)" : "Message to \(targetWorkerId!.prefix(8)): \(text)", details: [
      "swarmId": swarmId,
      "isBroadcast": String(targetWorkerId == nil)
    ])
  }

  /// Start listening for messages in a swarm
  public func startMessageListener(swarmId: String) {
    if messageListeners[swarmId] != nil {
      logger.debug("Message listener already active for swarm \(swarmId)")
      return
    }

    let deviceId = WorkerCapabilities.current().deviceId

    // Only listen for recent messages (last 5 minutes) to avoid loading history
    let cutoff = Date().addingTimeInterval(-300)

    let listener = messagesCollection(swarmId: swarmId)
      .whereField("createdAt", isGreaterThan: Timestamp(date: cutoff))
      .order(by: "createdAt", descending: false)
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self, let snapshot = snapshot else {
          if let error = error {
            self?.logger.error("Message listener error for swarm \(swarmId): \(error)")
            Task { @MainActor in
              self?.logActivity(.error, message: "Message listener error", details: [
                "swarmId": swarmId,
                "error": error.localizedDescription
              ])
            }
          }
          return
        }

        Task { @MainActor in
          for change in snapshot.documentChanges where change.type == .added {
            let data = change.document.data()
            let senderDeviceId = data["senderDeviceId"] as? String ?? ""

            // Skip messages from self
            guard senderDeviceId != deviceId else { continue }

            // Skip targeted messages not for us
            if let target = data["targetWorkerId"] as? String, target != deviceId {
              continue
            }

            let message = SwarmMessage(
              id: change.document.documentID,
              senderId: data["senderId"] as? String ?? "",
              senderDeviceId: senderDeviceId,
              senderName: data["senderName"] as? String ?? "Unknown",
              text: data["text"] as? String ?? "",
              createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
              isBroadcast: data["isBroadcast"] as? Bool ?? true,
              targetWorkerId: data["targetWorkerId"] as? String
            )

            self.swarmMessages.append(message)
            // Keep only last 50 messages
            if self.swarmMessages.count > 50 {
              self.swarmMessages.removeFirst(self.swarmMessages.count - 50)
            }

            self.logActivity(.messageReceived, message: "\(message.isBroadcast ? "📢" : "💬") \(message.senderName): \(message.text)", details: [
              "senderId": message.senderId,
              "isBroadcast": String(message.isBroadcast)
            ])
          }
        }
      }
    messageListeners[swarmId] = listener
    logActivity(.listenerStarted, message: "Message listener started", details: ["swarmId": swarmId])
  }

  /// Stop message listener for a specific swarm
  public func stopMessageListener(swarmId: String) {
    if let listener = messageListeners.removeValue(forKey: swarmId) {
      listener.remove()
    }
  }

  private func stopMessageListeners() {
    for (_, listener) in messageListeners {
      listener.remove()
    }
    messageListeners.removeAll()
    swarmMessages.removeAll()
  }

  // MARK: - Membership Listener (Real-time swarm list updates)
  
  /// Start listening for changes to the user's swarm memberships
  private func startMembershipListener(userId: String) {
    stopMembershipListener()
    
    logger.info("Starting membership listener for user: \(userId)")
    
    // Listen to all membership documents for this user via collection group
    membershipListener = db.collectionGroup("members")
      .whereField("userId", isEqualTo: userId)
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self else { return }
        
        if let error = error {
          self.logger.error("Membership listener error: \(error)")
          return
        }
        
        guard let snapshot = snapshot else { return }
        
        self.logger.info("Membership snapshot received: \(snapshot.documents.count) memberships")
        
        Task { @MainActor in
          await self.processMembershipSnapshot(snapshot, userId: userId)
        }
      }
  }
  
  /// Process membership snapshot and update memberSwarms
  private func processMembershipSnapshot(_ snapshot: QuerySnapshot, userId: String) async {
    var swarms: [SwarmMembership] = []
    var seenSwarmIds = Set<String>()
    
    for memberDoc in snapshot.documents {
      // Extract swarm ID from path: swarms/{swarmId}/members/{userId}
      let pathComponents = memberDoc.reference.path.split(separator: "/")
      guard pathComponents.count >= 2,
            let swarmIdIndex = pathComponents.firstIndex(of: "swarms"),
            swarmIdIndex + 1 < pathComponents.count else {
        continue
      }
      let swarmId = String(pathComponents[swarmIdIndex + 1])
      
      guard !seenSwarmIds.contains(swarmId) else { continue }
      seenSwarmIds.insert(swarmId)
      
      let memberData = memberDoc.data()
      let roleString = memberData["role"] as? String ?? "reader"
      let role = SwarmPermissionRole(rawValue: roleString) ?? .reader
      let joinedAt = (memberData["joinedAt"] as? Timestamp)?.dateValue() ?? Date()
      
      // Fetch swarm name (cached in most cases)
      let swarmDoc = try? await swarmsCollection().document(swarmId).getDocument()
      let swarmName = swarmDoc?.data()?["name"] as? String ?? "Unknown Swarm"
      
      swarms.append(SwarmMembership(
        id: swarmId,
        swarmName: swarmName,
        role: role,
        joinedAt: joinedAt
      ))
    }
    
    // Also check for owned swarms (in case owner isn't in members collection)
    do {
      let ownedSwarms = try await swarmsCollection()
        .whereField("ownerId", isEqualTo: userId)
        .getDocuments()
      
      for swarmDoc in ownedSwarms.documents {
        let swarmId = swarmDoc.documentID
        guard !seenSwarmIds.contains(swarmId) else { continue }
        seenSwarmIds.insert(swarmId)
        
        let swarmData = swarmDoc.data()
        let swarmName = swarmData["name"] as? String ?? "Unknown"
        
        swarms.append(SwarmMembership(
          id: swarmId,
          swarmName: swarmName,
          role: .owner,
          joinedAt: Date()
        ))
      }
    } catch {
      logger.warning("Failed to fetch owned swarms: \(error)")
    }
    
    // Only update if changed
    if swarms != memberSwarms {
      logger.info("Membership changed: \(self.memberSwarms.count) -> \(swarms.count) swarms")
      memberSwarms = swarms
    }
  }
  
  private func stopMembershipListener() {
    membershipListener?.remove()
    membershipListener = nil
  }
  
  // MARK: - Swarm Detail Listeners (Members and Invites)
  
  /// Start listening for members of a specific swarm (for swarm detail view)
  public func startMembersListener(swarmId: String) {
    stopMembersListener()
    
    logger.info("Starting members listener for swarm: \(swarmId)")
    
    membersListener = membersCollection(swarmId: swarmId)
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self else { return }
        
        if let error = error {
          self.logger.error("Members listener error: \(error)")
          return
        }
        
        guard let snapshot = snapshot else { return }
        
        Task { @MainActor in
          let allMembers = snapshot.documents.compactMap { doc -> SwarmMember? in
            let data = doc.data()
            return SwarmMember(
              id: doc.documentID,
              displayName: data["displayName"] as? String ?? "Unknown",
              email: data["email"] as? String ?? "",
              role: SwarmPermissionRole(rawValue: data["role"] as? String ?? "pending") ?? .pending,
              joinedAt: (data["joinedAt"] as? Timestamp)?.dateValue() ?? Date(),
              approvedBy: data["approvedBy"] as? String
            )
          }
          
          // Split into approved and pending
          self.swarmMembers = allMembers.filter { $0.role != .pending }
          self.pendingMembers = allMembers.filter { $0.role == .pending }
          
          self.logger.info("Members updated: \(self.swarmMembers.count) approved, \(self.pendingMembers.count) pending")
        }
      }
  }
  
  public func stopMembersListener() {
    membersListener?.remove()
    membersListener = nil
  }
  
  /// Start listening for invites of a specific swarm
  public func startInvitesListener(swarmId: String, onUpdate: @escaping ([InviteDetails]) -> Void) {
    stopInvitesListener()
    
    logger.info("Starting invites listener for swarm: \(swarmId)")
    
    invitesListener = invitesCollection(swarmId: swarmId)
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self else { return }
        
        if let error = error {
          self.logger.error("Invites listener error: \(error)")
          return
        }
        
        guard let snapshot = snapshot else { return }
        
        let invites = snapshot.documents.compactMap { doc -> InviteDetails? in
          let data = doc.data()
          guard let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(),
                let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() else {
            return nil
          }
          
          return InviteDetails(
            id: doc.documentID,
            swarmId: swarmId,
            token: data["token"] as? String ?? "",
            createdAt: createdAt,
            expiresAt: expiresAt,
            maxUses: data["maxUses"] as? Int ?? 1,
            usedCount: data["usedCount"] as? Int ?? 0,
            usedBy: data["usedBy"] as? [String] ?? [],
            createdBy: data["createdBy"] as? String ?? "",
            isRevoked: data["isRevoked"] as? Bool ?? false
          )
        }
        
        self.logger.info("Invites updated: \(invites.count) invites")
        onUpdate(invites)
      }
  }
  
  public func stopInvitesListener() {
    invitesListener?.remove()
    invitesListener = nil
  }
  
  // MARK: - Task Management (#225)
  
  /// Delegate for task execution (set by SwarmCoordinator or similar)
  public weak var taskExecutionDelegate: FirestoreTaskExecutionDelegate?
  
  /// Submit a task to the swarm
  public func submitTask(
    swarmId: String,
    request: ChainRequest
  ) async throws -> String {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission (contributor+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 2 else {
      throw FirebaseError.permissionDenied
    }
    
    let taskRef = tasksCollection(swarmId: swarmId).document(request.id.uuidString)
    
    try await taskRef.setData([
      "templateName": request.templateName,
      "prompt": request.prompt,
      "workingDirectory": request.workingDirectory,
      "repoRemoteURL": request.repoRemoteURL as Any,
      "priority": request.priority.rawValue,
      "timeoutSeconds": request.timeoutSeconds,
      "status": ChainStatus.pending.rawValue,
      "createdBy": userId,
      "createdAt": FieldValue.serverTimestamp(),
      "claimedBy": NSNull(),
      "claimedAt": NSNull(),
      "completedAt": NSNull(),
      "result": NSNull()
    ])
    
    logger.info("Submitted task \(request.id) to swarm \(swarmId)")
    logActivity(.taskSubmitted, message: "Task submitted: \(request.templateName)", details: [
      "taskId": request.id.uuidString,
      "template": request.templateName,
      "prompt": String(request.prompt.prefix(50)) + (request.prompt.count > 50 ? "..." : "")
    ])
    return request.id.uuidString
  }
  
  /// Claim a task for execution
  /// Note: Uses simple check-and-update. For high-contention scenarios,
  /// a transaction-based approach via Cloud Functions would be more robust.
  public func claimTask(swarmId: String, taskId: String) async throws -> Bool {
    guard let userId = currentUserId,
          let workerId = registeredWorkerId else {
      throw FirebaseError.notSignedIn
    }
    
    let taskRef = tasksCollection(swarmId: swarmId).document(taskId)
    
    // First check if task is still pending
    let taskDoc = try await taskRef.getDocument()
    guard let data = taskDoc.data(),
          let status = data["status"] as? String,
          status == ChainStatus.pending.rawValue else {
      logger.debug("Task \(taskId) is not pending, cannot claim")
      return false
    }
    
    // Check if already claimed
    if let claimedBy = data["claimedBy"] as? String, !claimedBy.isEmpty {
      logger.debug("Task \(taskId) already claimed by \(claimedBy)")
      return false
    }
    
    // Try to claim it
    do {
      try await taskRef.updateData([
        "status": ChainStatus.claimed.rawValue,
        "claimedBy": userId,
        "claimedByWorker": workerId,
        "claimedAt": FieldValue.serverTimestamp()
      ])
      logger.info("Claimed task \(taskId)")
      logActivity(.taskClaimed, message: "Claimed task", details: [
        "taskId": taskId,
        "workerId": workerId
      ])
      return true
    } catch {
      // Could fail if another worker claimed it first
      logger.warning("Failed to claim task \(taskId): \(error)")
      return false
    }
  }
  
  /// Update task status to running
  public func updateTaskRunning(swarmId: String, taskId: String) async throws {
    try await tasksCollection(swarmId: swarmId).document(taskId).updateData([
      "status": ChainStatus.running.rawValue
    ])
  }
  
  /// Complete a task with result
  public func completeTask(swarmId: String, taskId: String, result: ChainResult) async throws {
    let resultData: [String: Any] = [
      "requestId": result.requestId.uuidString,
      "status": result.status.rawValue,
      "duration": result.duration,
      "workerDeviceId": result.workerDeviceId,
      "workerDeviceName": result.workerDeviceName,
      "completedAt": Timestamp(date: result.completedAt),
      "errorMessage": result.errorMessage as Any,
      "branchName": result.branchName as Any,
      "repoPath": result.repoPath as Any,
      "outputCount": result.outputs.count
    ]
    
    try await tasksCollection(swarmId: swarmId).document(taskId).updateData([
      "status": result.status.rawValue,
      "completedAt": FieldValue.serverTimestamp(),
      "result": resultData
    ])
    
    logger.info("Completed task \(taskId) with status \(result.status.rawValue)")
    
    // Log success or failure
    if result.status == .completed {
      logActivity(.taskCompleted, message: "Task completed", details: [
        "taskId": taskId,
        "duration": "\(result.duration)s",
        "branch": result.branchName ?? "none"
      ])
    } else {
      logActivity(.taskFailed, message: "Task failed: \(result.errorMessage ?? "Unknown error")", details: [
        "taskId": taskId,
        "status": result.status.rawValue
      ])
    }
  }
  
  /// Start listening for tasks assigned to this worker
  private func startTaskListener(swarmId: String, workerId: String) {
    stopTaskListener()
    
    logActivity(.listenerStarted, message: "Task listener started", details: [
      "swarmId": swarmId,
      "workerId": workerId
    ])
    
    // Listen for pending tasks that we might claim
    taskListener = tasksCollection(swarmId: swarmId)
      .whereField("status", isEqualTo: ChainStatus.pending.rawValue)
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self, let snapshot = snapshot else {
          if let error = error {
            self?.logger.error("Task listener error: \(error)")
          }
          return
        }
        
        Task { @MainActor in
          // Process new pending tasks
          for change in snapshot.documentChanges where change.type == .added {
            let doc = change.document
            let data = doc.data()
            
            // Try to claim and execute the task
            guard let templateName = data["templateName"] as? String,
                  let prompt = data["prompt"] as? String,
                  let workingDir = data["workingDirectory"] as? String,
                  let taskId = UUID(uuidString: doc.documentID) else {
              continue
            }
            
            let request = ChainRequest(
              id: taskId,
              templateName: templateName,
              prompt: prompt,
              workingDirectory: workingDir,
              repoRemoteURL: data["repoRemoteURL"] as? String,
              priority: ChainPriority(rawValue: data["priority"] as? Int ?? 1) ?? .normal,
              timeoutSeconds: data["timeoutSeconds"] as? Int ?? 300
            )
            
            // Try to claim the task
            Task {
              await self.tryClaimAndExecute(swarmId: swarmId, taskId: doc.documentID, request: request)
            }
          }
        }
      }
  }
  
  private func stopTaskListener() {
    if taskListener != nil {
      logActivity(.listenerStopped, message: "Task listener stopped")
    }
    taskListener?.remove()
    taskListener = nil
  }
  
  /// Try to claim and execute a task
  private func tryClaimAndExecute(swarmId: String, taskId: String, request: ChainRequest) async {
    do {
      let claimed = try await claimTask(swarmId: swarmId, taskId: taskId)
      guard claimed else {
        logger.debug("Task \(taskId) already claimed by another worker")
        return
      }
      
      try await updateTaskRunning(swarmId: swarmId, taskId: taskId)
      
      // Execute via delegate (bridges to SwarmCoordinator/ChainExecutor)
      if let delegate = taskExecutionDelegate {
        let result = await delegate.executeTask(request)
        try await completeTask(swarmId: swarmId, taskId: taskId, result: result)
      } else {
        // No executor configured - fail the task
        let failResult = ChainResult(
          requestId: request.id,
          status: .failed,
          duration: 0,
          workerDeviceId: registeredWorkerId ?? "unknown",
          workerDeviceName: "Unknown",
          errorMessage: "No task executor configured"
        )
        try await completeTask(swarmId: swarmId, taskId: taskId, result: failResult)
      }
    } catch {
      logger.error("Failed to execute task \(taskId): \(error)")
    }
  }
  
  /// Start listening for all pending tasks (for brain/dispatch view)
  public func startPendingTaskListener(swarmId: String) {
    let listener = tasksCollection(swarmId: swarmId)
      .whereField("status", in: [ChainStatus.pending.rawValue, ChainStatus.claimed.rawValue, ChainStatus.running.rawValue])
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self, let snapshot = snapshot else { return }
        
        Task { @MainActor in
          self.pendingTasks = snapshot.documents.compactMap { doc -> FirestoreTask? in
            let data = doc.data()
            guard let statusStr = data["status"] as? String,
                  let status = ChainStatus(rawValue: statusStr) else {
              return nil
            }
            
            return FirestoreTask(
              id: doc.documentID,
              templateName: data["templateName"] as? String ?? "",
              prompt: data["prompt"] as? String ?? "",
              status: status,
              createdBy: data["createdBy"] as? String ?? "",
              createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
              claimedBy: data["claimedBy"] as? String,
              claimedByWorker: data["claimedByWorker"] as? String
            )
          }
        }
      }
    swarmListeners.append(listener)
  }
  
  // MARK: - RAG Artifact Sync (#226)
  
  /// Firestore has a 1MB document limit, so we chunk large artifacts
  private static let maxChunkSize = 900_000  // 900KB to leave room for metadata
  
  /// Push RAG artifacts to Firestore for sharing with swarm members
  ///
  /// Large bundles are split into chunks stored in a subcollection.
  /// Format:
  /// - ragArtifacts/{artifactId}: manifest + metadata
  /// - ragArtifacts/{artifactId}/chunks/{chunkIndex}: binary data
  public func pushRAGArtifacts(
    swarmId: String,
    bundle: LocalRAGArtifactBundle
  ) async throws -> String {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission (contributor+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 2 else {
      throw FirebaseError.permissionDenied
    }
    
    let artifactId = bundle.manifest.version
    let collection = ragArtifactsCollection(swarmId: swarmId)
    let artifactRef = collection.document(artifactId)
    
    // Read the bundle data
    let bundleData = try Data(contentsOf: bundle.bundleURL)
    let totalBytes = bundleData.count
    
    // Update sync state for UI
    await MainActor.run {
      ragSyncState = FirestoreRAGSyncState(
        direction: .push,
        artifactId: artifactId,
        status: .uploading,
        totalBytes: totalBytes,
        transferredBytes: 0,
        startedAt: Date()
      )
    }
    
    // Store manifest document
    let manifestData = try JSONEncoder().encode(bundle.manifest)
    let manifestJSON = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] ?? [:]
    
    try await artifactRef.setData([
      "version": bundle.manifest.version,
      "formatVersion": bundle.manifest.formatVersion,
      "schemaVersion": bundle.manifest.schemaVersion,
      "totalBytes": totalBytes,
      "chunkCount": (totalBytes + Self.maxChunkSize - 1) / Self.maxChunkSize,
      "embeddingCacheCount": bundle.manifest.embeddingCacheCount,
      "repoCount": bundle.manifest.repos.count,
      "createdAt": Timestamp(date: bundle.manifest.createdAt),
      "uploadedBy": userId,
      "uploadedAt": FieldValue.serverTimestamp(),
      "manifest": manifestJSON
    ])
    
    // Upload chunks
    let chunkCount = (totalBytes + Self.maxChunkSize - 1) / Self.maxChunkSize
    var transferred = 0
    
    for i in 0..<chunkCount {
      let start = i * Self.maxChunkSize
      let end = min(start + Self.maxChunkSize, totalBytes)
      let chunk = bundleData[start..<end]
      
      try await artifactRef.collection("chunks").document(String(format: "%05d", i)).setData([
        "index": i,
        "data": chunk.base64EncodedString(),
        "size": chunk.count
      ])
      
      transferred = end
      await MainActor.run {
        ragSyncState?.transferredBytes = transferred
      }
    }
    
    // Mark upload complete
    await MainActor.run {
      ragSyncState?.status = .complete
      ragSyncState?.completedAt = Date()
    }
    
    logger.info("Pushed RAG artifact \(artifactId) to swarm \(swarmId) (\(chunkCount) chunks, \(totalBytes) bytes)")
    return artifactId
  }
  
  /// Pull RAG artifacts from Firestore
  ///
  /// Downloads the manifest and all chunks, reassembles into a local bundle.
  public func pullRAGArtifacts(
    swarmId: String,
    artifactId: String,
    destination: URL
  ) async throws -> RAGArtifactManifest {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission (reader+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 1 else {
      throw FirebaseError.permissionDenied
    }
    
    let collection = ragArtifactsCollection(swarmId: swarmId)
    let artifactRef = collection.document(artifactId)
    
    // Get the artifact document
    let doc = try await artifactRef.getDocument()
    guard doc.exists, let data = doc.data() else {
      throw RAGArtifactError.artifactNotFound(artifactId)
    }
    
    let totalBytes = data["totalBytes"] as? Int ?? 0
    let chunkCount = data["chunkCount"] as? Int ?? 0
    
    // Update sync state for UI
    await MainActor.run {
      ragSyncState = FirestoreRAGSyncState(
        direction: .pull,
        artifactId: artifactId,
        status: .downloading,
        totalBytes: totalBytes,
        transferredBytes: 0,
        startedAt: Date()
      )
    }
    
    // Parse manifest
    guard let manifestDict = data["manifest"] as? [String: Any] else {
      throw RAGArtifactError.invalidManifest
    }
    let manifestData = try JSONSerialization.data(withJSONObject: manifestDict)
    let manifest = try JSONDecoder().decode(RAGArtifactManifest.self, from: manifestData)
    
    // Download all chunks
    var assembledData = Data()
    assembledData.reserveCapacity(totalBytes)
    
    let chunksSnapshot = try await artifactRef.collection("chunks")
      .order(by: "index")
      .getDocuments()
    
    for chunkDoc in chunksSnapshot.documents {
      guard let base64 = chunkDoc.data()["data"] as? String,
            let chunkData = Data(base64Encoded: base64) else {
        throw RAGArtifactError.invalidChunk(chunkDoc.documentID)
      }
      
      assembledData.append(chunkData)
      
      await MainActor.run {
        ragSyncState?.transferredBytes = assembledData.count
      }
    }
    
    // Verify size
    guard assembledData.count == totalBytes else {
      throw RAGArtifactError.sizeMismatch(expected: totalBytes, actual: assembledData.count)
    }
    
    // Write to destination
    try assembledData.write(to: destination)
    
    // Mark download complete
    await MainActor.run {
      ragSyncState?.status = .complete
      ragSyncState?.completedAt = Date()
    }
    
    logger.info("Pulled RAG artifact \(artifactId) from swarm \(swarmId) (\(chunkCount) chunks, \(totalBytes) bytes)")
    return manifest
  }
  
  /// List available RAG artifacts in a swarm
  public func listRAGArtifacts(swarmId: String) async throws -> [FirestoreRAGArtifact] {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has permission (reader+)
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 1 else {
      throw FirebaseError.permissionDenied
    }
    
    let snapshot = try await ragArtifactsCollection(swarmId: swarmId)
      .order(by: "uploadedAt", descending: true)
      .limit(to: 20)
      .getDocuments()
    
    return snapshot.documents.compactMap { doc -> FirestoreRAGArtifact? in
      let data = doc.data()
      return FirestoreRAGArtifact(
        id: doc.documentID,
        version: data["version"] as? String ?? "",
        totalBytes: data["totalBytes"] as? Int ?? 0,
        chunkCount: data["chunkCount"] as? Int ?? 0,
        embeddingCacheCount: data["embeddingCacheCount"] as? Int ?? 0,
        repoCount: data["repoCount"] as? Int ?? 0,
        uploadedBy: data["uploadedBy"] as? String ?? "",
        uploadedAt: (data["uploadedAt"] as? Timestamp)?.dateValue() ?? Date()
      )
    }
  }
  
  /// Delete a RAG artifact from Firestore
  public func deleteRAGArtifact(swarmId: String, artifactId: String) async throws {
    guard let userId = currentUserId else { throw FirebaseError.notSignedIn }
    
    // Verify user has admin permission
    let memberDoc = try await membersCollection(swarmId: swarmId).document(userId).getDocument()
    guard let roleLevel = memberDoc.data()?["roleLevel"] as? Int, roleLevel >= 3 else {
      throw FirebaseError.permissionDenied
    }
    
    let artifactRef = ragArtifactsCollection(swarmId: swarmId).document(artifactId)
    
    // Delete all chunks first
    let chunks = try await artifactRef.collection("chunks").getDocuments()
    for chunk in chunks.documents {
      try await chunk.reference.delete()
    }
    
    // Delete the artifact document
    try await artifactRef.delete()
    
    logger.info("Deleted RAG artifact \(artifactId) from swarm \(swarmId)")
  }
  
  /// Start listening for RAG artifacts in a swarm
  public func startRAGArtifactListener(swarmId: String) {
    let listener = ragArtifactsCollection(swarmId: swarmId)
      .order(by: "uploadedAt", descending: true)
      .limit(to: 20)
      .addSnapshotListener { [weak self] snapshot, error in
        guard let self = self, let snapshot = snapshot else {
          if let error = error {
            self?.logger.error("RAG artifact listener error: \(error)")
          }
          return
        }
        
        Task { @MainActor in
          self.ragArtifacts = snapshot.documents.compactMap { doc -> FirestoreRAGArtifact? in
            let data = doc.data()
            return FirestoreRAGArtifact(
              id: doc.documentID,
              version: data["version"] as? String ?? "",
              totalBytes: data["totalBytes"] as? Int ?? 0,
              chunkCount: data["chunkCount"] as? Int ?? 0,
              embeddingCacheCount: data["embeddingCacheCount"] as? Int ?? 0,
              repoCount: data["repoCount"] as? Int ?? 0,
              uploadedBy: data["uploadedBy"] as? String ?? "",
              uploadedAt: (data["uploadedAt"] as? Timestamp)?.dateValue() ?? Date()
            )
          }
        }
      }
    swarmListeners.append(listener)
  }
  
  // MARK: - Listeners
  
  private func removeSwarmListeners() {
    for listener in swarmListeners {
      listener.remove()
    }
    swarmListeners.removeAll()
    stopMembersListener()
    stopInvitesListener()
    stopWorkerListeners()
    stopMessageListeners()
    stopTaskListener()
    stopHeartbeatLoop()
  }
  
  // MARK: - Helper Functions
  
  private func generateSecureToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  
  private func randomNonceString(length: Int = 32) -> String {
    precondition(length > 0)
    var randomBytes = [UInt8](repeating: 0, count: length)
    let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
    if errorCode != errSecSuccess {
      fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
    }
    let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    return String(randomBytes.map { charset[Int($0) % charset.count] })
  }
  
  private func sha256(_ input: String) -> String {
    let inputData = Data(input.utf8)
    let hashed = SHA256.hash(data: inputData)
    return hashed.compactMap { String(format: "%02x", $0) }.joined()
  }
  
  // MARK: - Deep Link Handling
  
  /// Handle a peel:// URL (for invite acceptance)
  public func handleDeepLink(_ url: URL) async {
    guard url.scheme == "peel" else { return }
    
    logger.info("Handling deep link: \(url)")
    
    // Reset state
    lastDeepLinkError = nil
    pendingInvitePreview = nil
    deepLinkReceived = true
    
    // Ensure Firebase is configured before accessing Firestore
    guard isConfigured else {
      lastDeepLinkError = "Firebase not configured"
      logger.error("Firebase not configured, cannot handle deep link")
      return
    }
    
    // Parse URL first to validate format
    guard url.host == "swarm",
          url.pathComponents.contains("join"),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let _ = components.queryItems?.first(where: { $0.name == "s" })?.value,
          let _ = components.queryItems?.first(where: { $0.name == "i" })?.value,
          let _ = components.queryItems?.first(where: { $0.name == "t" })?.value
    else {
      lastDeepLinkError = "Invalid invite link format"
      logger.error("Invalid invite URL format")
      return
    }
    
    // Must be signed in to preview invites - store URL for later
    guard isSignedIn else {
      pendingInviteURL = url
      lastDeepLinkError = "Sign in to accept this invite"
      logger.warning("User not signed in, storing invite URL for after auth")
      return
    }
    
    // Fetch preview instead of immediately accepting (#237)
    do {
      let preview = try await fetchInvitePreview(url: url)
      pendingInvitePreview = preview
      pendingInviteURL = url
      logger.info("Showing invite preview for swarm: \(preview.swarmName)")
    } catch {
      lastDeepLinkError = error.localizedDescription
      logger.error("Failed to fetch invite preview: \(error)")
    }
  }
  
  /// Accept the pending invite preview
  public func acceptPendingInvite() async {
    guard let preview = pendingInvitePreview else { return }
    
    do {
      try await acceptInvite(url: preview.url)
      pendingInvitePreview = nil
      pendingInviteURL = nil
      lastDeepLinkError = nil
      logger.info("Successfully accepted invite to: \(preview.swarmName)")
    } catch {
      lastDeepLinkError = error.localizedDescription
      logger.error("Failed to accept invite: \(error)")
    }
  }
  
  /// Dismiss the pending invite preview without accepting
  public func dismissInvitePreview() {
    pendingInvitePreview = nil
    pendingInviteURL = nil
    lastDeepLinkError = nil
  }
  
  /// Process any pending invite after sign-in (fetches preview for user to confirm)
  public func processPendingInvite() async {
    guard let url = pendingInviteURL, isSignedIn else { return }
    
    logger.info("Processing pending invite after sign-in")
    
    // Fetch preview instead of auto-accepting (#237)
    do {
      let preview = try await fetchInvitePreview(url: url)
      pendingInvitePreview = preview
      deepLinkReceived = true
      logger.info("Showing invite preview after sign-in for swarm: \(preview.swarmName)")
    } catch {
      lastDeepLinkError = error.localizedDescription
      pendingInviteURL = nil
      deepLinkReceived = true
      logger.error("Failed to fetch invite preview after sign-in: \(error)")
    }
  }
}

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
  
  /// WAN connection info for direct peer-to-peer connections
  public let wanAddress: String?
  public let wanPort: UInt16?
  
  /// STUN-discovered endpoint (NAT-mapped address:port for UDP hole punching)
  public let stunAddress: String?
  public let stunPort: UInt16?
  
  /// Whether the worker is considered stale (no heartbeat in 90 seconds)
  public var isStale: Bool {
    Date().timeIntervalSince(lastHeartbeat) > 90
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

// MARK: - Firestore RAG Artifact Types (#226)

/// A RAG artifact stored in Firestore
public struct FirestoreRAGArtifact: Sendable, Identifiable, Hashable {
  public let id: String  // artifactId (usually version string)
  public let version: String
  public let totalBytes: Int
  public let chunkCount: Int
  public let embeddingCacheCount: Int
  public let repoCount: Int
  public let uploadedBy: String
  public let uploadedAt: Date
  
  /// Human-readable size
  public var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
  }
}

/// Sync state for RAG artifact transfer
public struct FirestoreRAGSyncState: Sendable {
  public let direction: RAGArtifactSyncDirection
  public let artifactId: String
  public var status: FirestoreRAGSyncStatus
  public let totalBytes: Int
  public var transferredBytes: Int
  public let startedAt: Date
  public var completedAt: Date?
  public var errorMessage: String?
  
  /// Progress as a value from 0.0 to 1.0
  public var progress: Double {
    guard totalBytes > 0 else { return status == .complete ? 1.0 : 0 }
    return min(1, Double(transferredBytes) / Double(totalBytes))
  }
}

/// Status of a RAG sync operation
public enum FirestoreRAGSyncStatus: String, Sendable {
  case uploading
  case downloading
  case complete
  case failed
}

/// Errors specific to RAG artifact operations
public enum RAGArtifactError: LocalizedError {
  case artifactNotFound(String)
  case invalidManifest
  case invalidChunk(String)
  case sizeMismatch(expected: Int, actual: Int)
  
  public var errorDescription: String? {
    switch self {
    case .artifactNotFound(let id): return "RAG artifact not found: \(id)"
    case .invalidManifest: return "Invalid artifact manifest"
    case .invalidChunk(let id): return "Invalid or corrupted chunk: \(id)"
    case .sizeMismatch(let expected, let actual):
      return "Size mismatch: expected \(expected) bytes, got \(actual)"
    }
  }
}
