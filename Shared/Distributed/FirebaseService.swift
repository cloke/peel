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
  
  // MARK: - Private State
  
  private var authStateListener: AuthStateDidChangeListenerHandle?
  private var swarmListeners: [ListenerRegistration] = []
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
  
  // MARK: - Initialization
  
  private init() {}
  
  // MARK: - Configuration
  
  /// Configure Firebase. Call this in PeelApp.init()
  public func configure() {
    guard !isConfigured else {
      logger.warning("Firebase already configured")
      return
    }
    
    FirebaseApp.configure()
    logger.info("Firebase configured successfully")
    
    // Configure Firestore settings before first use
    let settings = FirestoreSettings()
    settings.cacheSettings = PersistentCacheSettings()
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
      currentUserDisplayName = user.displayName
      logger.info("User signed in: \(user.uid)")
      Task {
        await loadUserSwarms()
      }
    } else {
      currentUserId = nil
      currentUserEmail = nil
      currentUserDisplayName = nil
      memberSwarms = []
      activeSwarm = nil
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
    guard let userId = currentUserId else { return }
    
    do {
      // First, get swarms where user is owner (we can always read those)
      let ownedSwarms = try await swarmsCollection()
        .whereField("ownerId", isEqualTo: userId)
        .getDocuments()
      
      var swarms: [SwarmMembership] = []
      
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
      }
      
      // TODO: Also query for swarms where user is a member but not owner
      // This requires either:
      // 1. A collection group query with userId stored in member doc
      // 2. A separate user-swarms mapping collection
      // For now, owners can see their owned swarms
      
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
    
    // Create owner membership (include oderId for collection group queries)
    batch.setData([
      "userId": userId,
      "displayName": currentUserDisplayName ?? "Owner",
      "email": currentUserEmail ?? "",
      "joinedAt": FieldValue.serverTimestamp(),
      "role": "owner",
      "roleLevel": 4,
      "status": "active",
      "workers": []
    ], forDocument: membersCollection(swarmId: swarmId).document(userId))
    
    try await batch.commit()
    logger.info("Created swarm: \(swarmId)")
    
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
    
    // Add user as pending member
    batch.setData([
      "displayName": currentUserDisplayName ?? "New Member",
      "email": currentUserEmail ?? "",
      "joinedAt": FieldValue.serverTimestamp(),
      "invitedBy": inviteData["createdBy"] as? String ?? "",
      "role": "pending",
      "roleLevel": 0,
      "status": "active",
      "approvedBy": NSNull(),
      "approvedAt": NSNull(),
      "workers": []
    ], forDocument: membersCollection(swarmId: swarmId).document(userId))
    
    // Update invite usage
    batch.updateData([
      "usedBy": FieldValue.arrayUnion([userId])
    ], forDocument: inviteRef)
    
    try await batch.commit()
    logger.info("Successfully joined swarm \(swarmId) as pending member")
    
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
  
  // MARK: - Listeners
  
  private func removeSwarmListeners() {
    for listener in swarmListeners {
      listener.remove()
    }
    swarmListeners.removeAll()
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
    
    // Ensure Firebase is configured before accessing Firestore
    guard isConfigured else {
      logger.error("Firebase not configured, cannot handle deep link")
      return
    }
    
    // Must be signed in to accept invites
    guard isSignedIn else {
      logger.warning("User not signed in, cannot accept invite. URL: \(url)")
      // TODO: Store URL and prompt sign-in, then accept after auth
      return
    }
    
    // Parse: peel://swarm/join?s={swarmId}&i={inviteId}&t={token}
    guard url.host == "swarm",
          url.pathComponents.contains("join"),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let _ = components.queryItems?.first(where: { $0.name == "s" })?.value,
          let _ = components.queryItems?.first(where: { $0.name == "i" })?.value,
          let _ = components.queryItems?.first(where: { $0.name == "t" })?.value
    else {
      logger.error("Invalid invite URL format")
      return
    }
    
    do {
      try await acceptInvite(url: url)
    } catch {
      logger.error("Failed to accept invite: \(error)")
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

/// Firebase service errors
public enum FirebaseError: LocalizedError {
  case notConfigured
  case notSignedIn
  case notImplemented
  case invalidInvite
  case invalidCredential
  case permissionDenied
  case networkError(Error)
  
  public var errorDescription: String? {
    switch self {
    case .notConfigured: return "Firebase not configured"
    case .notSignedIn: return "Not signed in"
    case .notImplemented: return "Feature not yet implemented"
    case .invalidInvite: return "Invalid or expired invite"
    case .invalidCredential: return "Invalid Apple Sign-In credential"
    case .permissionDenied: return "Permission denied"
    case .networkError(let error): return "Network error: \(error.localizedDescription)"
    }
  }
}
