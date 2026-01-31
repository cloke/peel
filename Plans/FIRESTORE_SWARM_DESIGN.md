# Firestore Swarm Coordination Design

**Status:** Draft  
**Created:** 2026-01-30  
**Related:** DISTRIBUTED_PEEL_DESIGN.md

## Overview

Use Firebase/Firestore to coordinate Peel swarm workers across WAN, complementing Bonjour for LAN discovery. Security is paramount—unauthorized access could mean arbitrary code execution on swarm workers.

## Threat Model

| Threat | Impact | Mitigation |
|--------|--------|------------|
| Unauthorized worker joins swarm | Code execution on legitimate workers | Invite-only with cryptographic tokens |
| Stolen invite token | Attacker joins swarm | Time-limited invites, single-use tokens |
| Compromised worker | Malicious task injection | Per-worker auth, task signing |
| Credential leak | Full swarm compromise | Rotate keys, Firebase App Check |
| Slow revocation | Attacker persists after detection | Real-time revocation, short token TTL |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Firebase Project                         │
├─────────────────────────────────────────────────────────────┤
│  Authentication          │  Firestore                       │
│  ─────────────────       │  ──────────────────────────      │
│  • Apple Sign-In         │  /swarms/{swarmId}/              │
│  • Custom tokens         │    /members/{userId}             │
│  • Custom claims:        │    /workers/{workerId}           │
│    - swarmId             │    /tasks/{taskId}               │
│    - role (owner/member) │    /invites/{inviteId}           │
│    - workerId            │                                  │
└─────────────────────────────────────────────────────────────┘
```

## Security Model

### 1. Swarm Ownership

Each swarm has exactly one **owner** (the person who created it). The owner:
- Creates/revokes invites
- Removes members
- Deletes the swarm

```typescript
// Firestore document
/swarms/{swarmId}: {
  ownerId: "user_abc123",
  name: "Chris's Home Swarm",
  created: Timestamp,
  settings: {
    maxWorkers: 10,
    allowedCapabilities: ["code", "shell"],  // what tasks workers can run
    requireApproval: true  // owner must approve task results
  }
}
```

### 2. Invite System

**Invite Flow:**
```
Owner                          Invitee                       Firebase
  │                               │                              │
  │─── Create invite ────────────────────────────────────────────▶│
  │◀── Invite token + QR ────────────────────────────────────────│
  │                               │                              │
  │─── Share QR/link ────────────▶│                              │
  │                               │─── Scan/click ──────────────▶│
  │                               │◀── Auth challenge ───────────│
  │                               │─── Apple Sign-In ───────────▶│
  │                               │◀── Custom claims set ────────│
  │                               │                              │
  │◀────────────────────── Notify owner ─────────────────────────│
```

**Invite Document:**
```typescript
/swarms/{swarmId}/invites/{inviteId}: {
  token: "crypto_random_32_bytes_base64",  // Secret part
  created: Timestamp,
  expires: Timestamp,  // 24 hours max
  maxUses: 1,          // Single-use by default
  usedBy: [],          // Track who used it
  createdBy: "user_abc123",
  revoked: false
}
```

**Invite Link Format:**
```
peel://swarm/join?s={swarmId}&i={inviteId}&t={token}
```

**Security Properties:**
- ✅ Time-limited (default 24h, configurable 1h-7d)
- ✅ Single-use by default (prevents sharing)
- ✅ Cryptographically random token (32 bytes)
- ✅ Requires Apple Sign-In (identity verification)
- ✅ Owner notified on join
- ✅ Revocable before use

### 3. Member Management & Permission Tiers

**Two-Step Join Process:**
1. **Invite Accept** → User joins as `pending` (very limited access)
2. **Admin Approval** → User promoted to desired role tier

This prevents unauthorized access even if an invite link leaks.

**Permission Tiers:**

| Role | Level | Capabilities |
|------|-------|--------------|
| `owner` | 4 | Full control: manage swarm, members, settings, tasks |
| `admin` | 3 | Approve members, manage tasks, full RAG access |
| `contributor` | 2 | Submit tasks, run chains, read/write RAG |
| `reader` | 1 | Query RAG, view task status, pull artifacts |
| `pending` | 0 | View swarm info only, awaiting approval |

**Permission Matrix:**

| Action | owner | admin | contributor | reader | pending |
|--------|-------|-------|-------------|--------|---------|
| Create/delete swarm | ✅ | ❌ | ❌ | ❌ | ❌ |
| Invite members | ✅ | ✅ | ❌ | ❌ | ❌ |
| Approve pending members | ✅ | ✅ | ❌ | ❌ | ❌ |
| Promote/demote members | ✅ | ❌ | ❌ | ❌ | ❌ |
| Revoke members | ✅ | ✅ | ❌ | ❌ | ❌ |
| Submit tasks | ✅ | ✅ | ✅ | ❌ | ❌ |
| Claim/execute tasks | ✅ | ✅ | ✅ | ❌ | ❌ |
| View task status | ✅ | ✅ | ✅ | ✅ | ❌ |
| Query RAG (search) | ✅ | ✅ | ✅ | ✅ | ❌ |
| Write to RAG (index) | ✅ | ✅ | ✅ | ❌ | ❌ |
| Pull RAG artifacts | ✅ | ✅ | ✅ | ✅ | ❌ |
| Push RAG artifacts | ✅ | ✅ | ✅ | ❌ | ❌ |
| Register workers | ✅ | ✅ | ✅ | ❌ | ❌ |
| View swarm info | ✅ | ✅ | ✅ | ✅ | ✅ |

```typescript
/swarms/{swarmId}/members/{userId}: {
  displayName: "John's MacBook",
  email: "john@example.com",  // From Apple Sign-In
  joinedAt: Timestamp,
  invitedBy: "user_abc123",
  role: "pending",  // "owner" | "admin" | "contributor" | "reader" | "pending"
  roleLevel: 0,     // Numeric for easy comparison in security rules
  status: "active",  // "active" | "suspended" | "revoked"
  approvedBy: null,  // Set when admin approves
  approvedAt: null,
  lastSeen: Timestamp,
  workers: ["worker_xyz"]  // Their registered workers
}
```

**Approval Flow:**
```
Invitee                     Firebase                      Admin
   │                           │                            │
   │─── Accept invite ────────▶│                            │
   │◀── Added as "pending" ────│                            │
   │                           │─── Notify admins ─────────▶│
   │                           │                            │
   │                           │◀── Approve (set role) ─────│
   │◀── Promotion notified ────│                            │
   │                           │                            │
   │─── Now can participate ───│                            │
```

**Pending Member Notifications:**
```typescript
// Cloud Function: Notify admins when new pending member joins
export const onPendingMember = functions.firestore
  .document('swarms/{swarmId}/members/{userId}')
  .onCreate(async (snap, context) => {
    const member = snap.data();
    if (member.role !== 'pending') return;
    
    const swarmId = context.params.swarmId;
    const admins = await admin.firestore()
      .collection(`swarms/${swarmId}/members`)
      .where('roleLevel', '>=', 3)  // admin or owner
      .get();
    
    // Send push notification or in-app notification
    for (const adminDoc of admins.docs) {
      await admin.firestore()
        .collection(`users/${adminDoc.id}/notifications`)
        .add({
          type: 'pending_member',
          swarmId,
          memberName: member.displayName,
          memberEmail: member.email,
          createdAt: admin.firestore.FieldValue.serverTimestamp()
        });
    }
  });
```
```

### 4. Access Revocation

**Revocation must be FAST.** When you revoke someone:

1. **Immediate:** Set `status: "revoked"` in Firestore
2. **Real-time:** All clients listen to their member doc
3. **Token invalidation:** Firebase custom claims updated
4. **Worker disconnect:** Revoked workers get kicked within seconds

```swift
// Client-side listener (Swift)
func observeMembershipStatus() {
    let memberRef = db.collection("swarms/\(swarmId)/members/\(userId)")
    
    memberRef.addSnapshotListener { snapshot, error in
        guard let data = snapshot?.data(),
              let status = data["status"] as? String else { return }
        
        if status == "revoked" || status == "suspended" {
            // IMMEDIATELY disconnect and clear local state
            self.disconnectFromSwarm()
            self.clearLocalCredentials()
            self.showRevocationAlert()
        }
    }
}
```

**Revocation Checklist:**
- [ ] Member document status → "revoked"
- [ ] Remove from workers collection
- [ ] Invalidate Firebase custom claims (force re-auth)
- [ ] Cancel any in-flight tasks from their workers
- [ ] Log revocation event for audit

### 5. Worker Authentication

Each worker (device) gets its own identity:

```typescript
/swarms/{swarmId}/workers/{workerId}: {
  ownerId: "user_abc123",  // Which member owns this worker
  displayName: "Mac Studio",
  capabilities: ["swift", "shell", "docker"],
  status: "online",  // "online" | "offline" | "busy"
  lastHeartbeat: Timestamp,
  publicKey: "base64_ed25519_public_key",  // For task signing
  ipAddress: "192.168.1.100",  // Last known (for debugging)
  version: "1.2.3"
}
```

**Task Signing:**
Tasks are signed by the brain, verified by workers:

```swift
struct SignedTask: Codable {
    let task: SwarmTask
    let signature: Data  // Ed25519 signature
    let brainPublicKey: Data
    let timestamp: Date
}

// Worker verifies before executing
func verifyTask(_ signedTask: SignedTask) -> Bool {
    // 1. Check brain's public key is in trusted list
    guard trustedBrains.contains(signedTask.brainPublicKey) else {
        return false
    }
    
    // 2. Check timestamp is recent (prevent replay)
    guard signedTask.timestamp.timeIntervalSinceNow > -300 else {
        return false
    }
    
    // 3. Verify signature
    return Ed25519.verify(
        signature: signedTask.signature,
        message: signedTask.task.encoded,
        publicKey: signedTask.brainPublicKey
    )
}
```

## Firestore Security Rules

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    
    // Helper functions
    function isAuthenticated() {
      return request.auth != null;
    }
    
    function isSwarmOwner(swarmId) {
      return isAuthenticated() && 
             get(/databases/$(database)/documents/swarms/$(swarmId)).data.ownerId == request.auth.uid;
    }
    
    function getMyRole(swarmId) {
      return get(/databases/$(database)/documents/swarms/$(swarmId)/members/$(request.auth.uid)).data;
    }
    
    function isSwarmMember(swarmId) {
      return isAuthenticated() &&
             exists(/databases/$(database)/documents/swarms/$(swarmId)/members/$(request.auth.uid)) &&
             getMyRole(swarmId).status == "active";
    }
    
    function hasMinRole(swarmId, minLevel) {
      return isSwarmMember(swarmId) && getMyRole(swarmId).roleLevel >= minLevel;
    }
    
    function isAdmin(swarmId) {
      return hasMinRole(swarmId, 3);  // admin or owner
    }
    
    function isContributor(swarmId) {
      return hasMinRole(swarmId, 2);  // contributor+
    }
    
    function isReader(swarmId) {
      return hasMinRole(swarmId, 1);  // reader+
    }
    
    function hasSwarmClaim(swarmId) {
      return request.auth.token.swarmId == swarmId;
    }
    
    // Swarm documents
    match /swarms/{swarmId} {
      allow read: if isSwarmMember(swarmId);
      allow create: if isAuthenticated();  // Anyone can create a swarm
      allow update, delete: if isSwarmOwner(swarmId);
      
      // Members subcollection
      match /members/{userId} {
        allow read: if isSwarmMember(swarmId);
        // Self-join creates pending membership
        allow create: if isSwarmOwner(swarmId) || 
                        (isAuthenticated() && userId == request.auth.uid &&
                         request.resource.data.role == "pending" &&
                         request.resource.data.roleLevel == 0);
        // Admins can approve (change role/roleLevel), users can update non-role fields
        allow update: if isAdmin(swarmId) || 
                        (userId == request.auth.uid && 
                         !request.resource.data.diff(resource.data).affectedKeys()
                           .hasAny(['role', 'roleLevel', 'status', 'approvedBy', 'approvedAt']));
        // Only owner can promote to admin, admins can promote up to contributor
        allow delete: if isSwarmOwner(swarmId);
      }
      
      // Workers subcollection
      match /workers/{workerId} {
        allow read: if isReader(swarmId);
        // Contributors+ can register workers
        allow create, update: if isContributor(swarmId) && 
                                 request.resource.data.ownerId == request.auth.uid;
        allow delete: if isSwarmOwner(swarmId) || 
                        resource.data.ownerId == request.auth.uid;
      }
      
      // Invites subcollection
      match /invites/{inviteId} {
        allow read: if isAdmin(swarmId);
        allow create: if isAdmin(swarmId);
        allow update: if isAdmin(swarmId) ||
                        (isAuthenticated() && 
                         resource.data.revoked == false &&
                         resource.data.expires > request.time);
        allow delete: if isSwarmOwner(swarmId);
      }
      
      // Tasks subcollection
      match /tasks/{taskId} {
        // Readers can view, contributors+ can create/update
        allow read: if isReader(swarmId);
        allow create: if isContributor(swarmId) && 
                        request.resource.data.createdBy == request.auth.uid;
        allow update: if isContributor(swarmId) &&
                        (resource.data.createdBy == request.auth.uid ||
                         resource.data.claimedBy == request.auth.uid);
        allow delete: if isAdmin(swarmId);
      }
      
      // RAG artifacts subcollection
      match /ragArtifacts/{artifactId} {
        allow read: if isReader(swarmId);  // Readers can pull
        allow create, update: if isContributor(swarmId);  // Contributors+ can push
        allow delete: if isAdmin(swarmId);
      }
    }
    
    // User notifications (for approval alerts)
    match /users/{userId}/notifications/{notificationId} {
      allow read, write: if request.auth.uid == userId;
    }
  }
}
```

## Firebase App Check

Add App Check to prevent API abuse:

```swift
// In AppDelegate or App init
let providerFactory = AppCheckDebugProviderFactory()  // Dev
// let providerFactory = DeviceCheckProviderFactory()  // Prod
AppCheck.setAppCheckProviderFactory(providerFactory)

// Firestore requests now include App Check token
```

## Data Flow

### Creating a Swarm

```swift
func createSwarm(name: String) async throws -> Swarm {
    let user = Auth.auth().currentUser!
    
    let swarmRef = db.collection("swarms").document()
    let swarmId = swarmRef.documentID
    
    // Create swarm and owner membership atomically
    let batch = db.batch()
    
    batch.setData([
        "ownerId": user.uid,
        "name": name,
        "created": FieldValue.serverTimestamp(),
        "settings": [
            "maxWorkers": 10,
            "requireApproval": true
        ]
    ], forDocument: swarmRef)
    
    batch.setData([
        "displayName": user.displayName ?? "Unknown",
        "email": user.email ?? "",
        "joinedAt": FieldValue.serverTimestamp(),
        "role": "owner",
        "status": "active",
        "workers": []
    ], forDocument: swarmRef.collection("members").document(user.uid))
    
    try await batch.commit()
    
    // Set custom claims via Cloud Function
    try await Functions.functions().httpsCallable("setSwarmClaims").call([
        "swarmId": swarmId,
        "role": "owner"
    ])
    
    return Swarm(id: swarmId, name: name)
}
```

### Creating an Invite

```swift
func createInvite(
    swarmId: String,
    expiresIn: TimeInterval = 86400,  // 24 hours
    maxUses: Int = 1
) async throws -> SwarmInvite {
    let token = generateSecureToken(bytes: 32)
    let inviteRef = db.collection("swarms/\(swarmId)/invites").document()
    
    try await inviteRef.setData([
        "token": token,
        "created": FieldValue.serverTimestamp(),
        "expires": Timestamp(date: Date().addingTimeInterval(expiresIn)),
        "maxUses": maxUses,
        "usedBy": [],
        "createdBy": Auth.auth().currentUser!.uid,
        "revoked": false
    ])
    
    let inviteURL = URL(string: "peel://swarm/join?s=\(swarmId)&i=\(inviteRef.documentID)&t=\(token)")!
    
    return SwarmInvite(
        id: inviteRef.documentID,
        url: inviteURL,
        qrCode: generateQRCode(for: inviteURL),
        expiresAt: Date().addingTimeInterval(expiresIn)
    )
}

func generateSecureToken(bytes: Int) -> String {
    var data = Data(count: bytes)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
    return data.base64EncodedString()
}
```

### Accepting an Invite

```swift
func acceptInvite(swarmId: String, inviteId: String, token: String) async throws {
    // 1. Verify invite is valid (Cloud Function does this securely)
    let result = try await Functions.functions().httpsCallable("acceptSwarmInvite").call([
        "swarmId": swarmId,
        "inviteId": inviteId,
        "token": token
    ])
    
    // Cloud Function:
    // - Validates token matches
    // - Checks not expired
    // - Checks not revoked
    // - Checks maxUses not exceeded
    // - Adds user to members collection
    // - Updates usedBy array
    // - Sets custom claims
    
    // 2. Force token refresh to get new claims
    try await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
    
    // 3. Start listening to swarm
    startSwarmListeners(swarmId: swarmId)
}
```

### Revoking Access

```swift
func revokeMember(swarmId: String, userId: String) async throws {
    // 1. Update member status (triggers real-time listener on their end)
    try await db.document("swarms/\(swarmId)/members/\(userId)").updateData([
        "status": "revoked",
        "revokedAt": FieldValue.serverTimestamp(),
        "revokedBy": Auth.auth().currentUser!.uid
    ])
    
    // 2. Remove their workers
    let workers = try await db.collection("swarms/\(swarmId)/workers")
        .whereField("ownerId", isEqualTo: userId)
        .getDocuments()
    
    let batch = db.batch()
    for worker in workers.documents {
        batch.deleteDocument(worker.reference)
    }
    try await batch.commit()
    
    // 3. Cancel their in-flight tasks
    let tasks = try await db.collection("swarms/\(swarmId)/tasks")
        .whereField("claimedBy", isEqualTo: userId)
        .whereField("status", isEqualTo: "running")
        .getDocuments()
    
    for task in tasks.documents {
        try await task.reference.updateData([
            "status": "cancelled",
            "cancelledReason": "member_revoked"
        ])
    }
    
    // 4. Revoke custom claims (Cloud Function)
    try await Functions.functions().httpsCallable("revokeSwarmAccess").call([
        "swarmId": swarmId,
        "userId": userId
    ])
}
```

## Cloud Functions

Required Cloud Functions (Node.js/TypeScript):

```typescript
// functions/src/index.ts

import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

admin.initializeApp();

export const acceptSwarmInvite = functions.https.onCall(async (data, context) => {
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
    }
    
    const { swarmId, inviteId, token } = data;
    const db = admin.firestore();
    
    // Verify invite
    const inviteRef = db.doc(`swarms/${swarmId}/invites/${inviteId}`);
    const invite = await inviteRef.get();
    
    if (!invite.exists) {
        throw new functions.https.HttpsError('not-found', 'Invite not found');
    }
    
    const inviteData = invite.data()!;
    
    if (inviteData.token !== token) {
        throw new functions.https.HttpsError('permission-denied', 'Invalid token');
    }
    
    if (inviteData.revoked) {
        throw new functions.https.HttpsError('permission-denied', 'Invite revoked');
    }
    
    if (inviteData.expires.toDate() < new Date()) {
        throw new functions.https.HttpsError('permission-denied', 'Invite expired');
    }
    
    if (inviteData.usedBy.length >= inviteData.maxUses) {
        throw new functions.https.HttpsError('permission-denied', 'Invite fully used');
    }
    
    // Add member
    const batch = db.batch();
    
    batch.set(db.doc(`swarms/${swarmId}/members/${context.auth.uid}`), {
        displayName: context.auth.token.name || 'Unknown',
        email: context.auth.token.email || '',
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
        invitedBy: inviteData.createdBy,
        role: 'member',
        status: 'active',
        workers: []
    });
    
    batch.update(inviteRef, {
        usedBy: admin.firestore.FieldValue.arrayUnion(context.auth.uid)
    });
    
    await batch.commit();
    
    // Set custom claims
    await admin.auth().setCustomUserClaims(context.auth.uid, {
        swarmId: swarmId,
        role: 'member'
    });
    
    return { success: true };
});

export const revokeSwarmAccess = functions.https.onCall(async (data, context) => {
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
    }
    
    const { swarmId, userId } = data;
    
    // Verify caller is owner
    const swarm = await admin.firestore().doc(`swarms/${swarmId}`).get();
    if (swarm.data()?.ownerId !== context.auth.uid) {
        throw new functions.https.HttpsError('permission-denied', 'Only owner can revoke');
    }
    
    // Clear custom claims
    const user = await admin.auth().getUser(userId);
    const claims = user.customClaims || {};
    delete claims.swarmId;
    delete claims.role;
    await admin.auth().setCustomUserClaims(userId, claims);
    
    // Revoke refresh tokens (forces re-auth)
    await admin.auth().revokeRefreshTokens(userId);
    
    return { success: true };
});
```

## Implementation Phases

### Phase 1: Firebase Project Setup & Auth
- [ ] Create Firebase project (`peel-swarm`)
- [ ] Enable Authentication with Apple Sign-In
- [ ] Create Firestore database (production mode)
- [x] Add Firebase SDK to Xcode project
- [x] Configure URL scheme for `peel://` deep links
- [x] Implement `FirebaseService` singleton

### Phase 2: Core Auth & Invites
- [x] Apple Sign-In integration in SwiftUI
- [x] Swarm creation flow
- [x] Invite creation & QR code generation
- [x] Invite acceptance via deep link
- [x] Deploy security rules (v1)

### Phase 3: Tiered Permissions & Admin Approval
- [x] Pending member state (role: "pending", roleLevel: 0)
- [x] Admin approval UI (list pending, approve/reject)
- [x] Role promotion/demotion (owner → admin, admin → contributor, etc.)
- [x] Permission checks in Swift (wrapper around Firestore)
- [ ] Cloud Functions for approval notifications

### Phase 4: Worker Management
- [x] Worker registration in Firestore
- [x] Real-time presence updates (heartbeat)
- [x] Task dispatch via Firestore
- [x] Task claiming & execution
- [x] Permission-gated task submission
- [x] MCP tools: swarm.firestore.workers, register-worker, submit-task, tasks

### Phase 5: RAG Artifact Sync
- [x] RAG artifact collection in Firestore
- [x] Pull artifacts (reader+) - `swarm.firestore.rag.pull`
- [x] Push artifacts (contributor+) - `swarm.firestore.rag.push`
- [x] Chunked upload for large artifacts (Firestore 1MB limit)
- [x] List artifacts - `swarm.firestore.rag.artifacts`
- [x] Delete artifacts (admin+) - `swarm.firestore.rag.delete`
- [ ] Conflict resolution strategy (deferred - currently last-write-wins)

### Phase 6: Security Hardening
- [ ] Firebase App Check
- [ ] Task signing with Ed25519
- [ ] Audit logging
- [ ] Rate limiting
- [ ] Revocation testing (fast invalidation)

### Phase 7: Polish & UI
- [ ] Swarm management dashboard
- [ ] Member management (list, approve, promote, revoke)
- [ ] Invite history & analytics
- [ ] Activity feed with role-based filtering

## Cost Estimate

Firebase Spark (Free) tier limits:
- 1 GiB Firestore storage
- 10 GiB/month network egress
- 50K/day reads, 20K/day writes
- Cloud Functions: 125K/month invocations

For a small swarm (5 workers, 100 tasks/day):
- ~500 writes/day (heartbeats, tasks, status)
- ~2000 reads/day (listeners, queries)
- Well within free tier

At scale, Blaze (pay-as-you-go):
- Firestore: $0.18/100K reads, $0.18/100K writes
- ~$5-10/month for active swarm

## Open Questions

1. **Multi-swarm membership:** Can a user be in multiple swarms?
   - Probably yes, but custom claims would need to be a list

2. **Offline support:** What happens if Firebase is unreachable?
   - Fall back to Bonjour-only for LAN workers
   - Queue tasks locally until reconnected

3. **Task payload encryption:** Should task prompts be E2E encrypted?
   - Adds complexity but prevents Firebase from seeing code
   - Could use member public keys for group encryption

4. **Linux workers:** How do Linux workers authenticate?
   - Could use service accounts + custom tokens
   - Or require human to sign in and generate long-lived token

---

## Firebase Project Setup (Step-by-Step)

### Prerequisites
- Apple Developer account (for Sign-In with Apple)
- Firebase account (Google account)

### 1. Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Click "Create a project"
3. Name: `peel-swarm` (or similar)
4. Disable Google Analytics (not needed for MVP)
5. Click "Create project"

### 2. Enable Authentication

1. In Firebase Console → Authentication → Sign-in method
2. Enable "Apple" provider
3. Download the "Sign In with Apple" config:
   - Service ID: `com.crunchy-bananas.peel.auth` (must match bundle ID pattern)
   - Team ID: Your Apple Developer Team ID
   - Key ID: Create a new key in Apple Developer portal
   - Private Key: Download `.p8` file from Apple

**Apple Developer Portal Setup:**
1. Go to Certificates, Identifiers & Profiles
2. Identifiers → App IDs → Select Peel app
3. Enable "Sign In with Apple" capability
4. Keys → Create new key → Enable "Sign In with Apple"
5. Download the `.p8` key file (save it securely!)

### 3. Create Firestore Database

1. Firebase Console → Firestore Database → Create database
2. Choose "Production mode" (we'll deploy proper rules)
3. Select region: `us-central1` (or nearest)
4. Wait for provisioning

### 4. Deploy Security Rules

Save the security rules from this document to `firestore.rules`, then:

```bash
# Install Firebase CLI
npm install -g firebase-tools

# Login
firebase login

# Initialize project (in KitchenSink directory)
firebase init firestore

# Deploy rules
firebase deploy --only firestore:rules
```

### 5. Add Firebase SDK to Xcode

1. In Xcode: File → Add Package Dependencies
2. Enter: `https://github.com/firebase/firebase-ios-sdk`
3. Select version: 11.0.0+ (latest)
4. Add these products:
   - FirebaseAuth
   - FirebaseFirestore
   - FirebaseFunctions
   - FirebaseAppCheck

5. Download `GoogleService-Info.plist` from Firebase Console
6. Add to Xcode project (both macOS and iOS targets)

### 6. Configure URL Scheme

In `Info.plist` (both targets):
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.crunchy-bananas.peel</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>peel</string>
    </array>
  </dict>
</array>
```

### 7. Initialize Firebase in App

```swift
// PeelApp.swift
import Firebase

@main
struct PeelApp: App {
  init() {
    FirebaseApp.configure()
  }
  // ...
}
```

### 8. Deploy Cloud Functions

```bash
# In project root
firebase init functions

# Choose TypeScript
# Install dependencies
cd functions && npm install

# Copy function code from this document
# Deploy
firebase deploy --only functions
```

---

## Next Steps

1. Create Firebase project: `peel-swarm` (or similar)
2. Enable Authentication with Apple Sign-In
3. Create Firestore database
4. Deploy security rules
5. Implement SwarmAuthService in Swift
6. Build invite UI

Want me to start implementing Phase 1?
