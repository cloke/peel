# User Onboarding Plan

**Status:** Draft  
**Created:** January 31, 2026  
**Goal:** Streamline the experience for new users joining Peel and Firestore swarms

---

## Overview

This plan outlines the onboarding flow for new Peel users, covering:
1. **Solo users** — Using Peel standalone (local chains, RAG, MCP)
2. **Swarm members** — Joining an existing Firestore swarm via invite
3. **Swarm owners** — Creating and managing their own swarm

---

## Current State

### What Exists
| Feature | Status | Location |
|---------|--------|----------|
| Sign In with Apple | ✅ Implemented | [SwarmAuthView.swift](../Shared/Views/Swarm/SwarmAuthView.swift) |
| Create Swarm | ✅ Implemented | [SwarmManagementView.swift](../Shared/Views/Swarm/SwarmManagementView.swift) |
| Create Invite | ✅ Implemented | `FirebaseService.createInvite()` |
| Join via Invite | ⚠️ Partial | URL scheme `peel://swarm/join` exists but flow incomplete |
| Pending Approval | ✅ Implemented | Admin approval workflow in place |
| Member List | 🚧 Stub | Placeholder view exists |
| Invite QR Code | 🚧 Designed | In design doc, not implemented |

### What's Missing
1. **Welcome wizard** for first-time users
2. **Invite acceptance flow** (deep link handling → sign in → join)
3. **Onboarding checklist UI** (first chain, first RAG index, etc.)
4. **Push notifications** for pending member alerts
5. **Documentation/help** embedded in app

---

## Onboarding Flows

### Flow 1: Solo User (No Swarm)

```
┌─────────────────────────────────────────────────────────────────┐
│  First Launch                                                    │
├─────────────────────────────────────────────────────────────────┤
│  1. Welcome screen with value prop                              │
│  2. "Get Started Solo" vs "Join a Swarm"                        │
│  3. If solo:                                                    │
│     a. Select a repository to work with                         │
│     b. Run first chain (guided)                                 │
│     c. Index repository with RAG (optional)                     │
│  4. Show dashboard with "getting started" checklist             │
└─────────────────────────────────────────────────────────────────┘
```

**Tasks:**
- [ ] Create `WelcomeView.swift` — first-launch experience
- [ ] Add `OnboardingChecklistView.swift` — tracks completion
- [ ] Persist onboarding state in SwiftData
- [ ] Skip if user has existing data (returning user)

### Flow 2: Joining a Swarm (Invitee)

```
┌─────────────────────────────────────────────────────────────────┐
│  Invite Link Flow                                                │
├─────────────────────────────────────────────────────────────────┤
│  1. User receives invite link: peel://swarm/join?s=...&i=...    │
│  2. Link opens Peel (or App Store if not installed)             │
│  3. Peel shows invite preview:                                  │
│     - Swarm name                                                │
│     - Who invited them                                          │
│     - Expiration                                                │
│  4. User taps "Sign In with Apple" (if not signed in)           │
│  5. User joins as "pending"                                     │
│  6. Show "Awaiting Approval" state                              │
│  7. Once approved → show swarm dashboard                        │
└─────────────────────────────────────────────────────────────────┘
```

**Tasks:**
- [ ] Implement URL scheme handler for `peel://swarm/join`
- [ ] Create `InvitePreviewView.swift` — shows invite details before accepting
- [ ] Create `AwaitingApprovalView.swift` — waiting state after join
- [ ] Add push notification support for "You've been approved!"
- [ ] Handle expired/invalid invites gracefully

### Flow 3: Creating a Swarm (New Owner)

```
┌─────────────────────────────────────────────────────────────────┐
│  Create Swarm Flow                                               │
├─────────────────────────────────────────────────────────────────┤
│  1. User signs in with Apple                                    │
│  2. Taps "Create Swarm"                                         │
│  3. Enter swarm name                                            │
│  4. Configure settings:                                         │
│     - Max workers                                               │
│     - Require approval for new members                          │
│     - Allowed capabilities (shell, docker, etc.)                │
│  5. Swarm created → show invite generation                      │
│  6. Share invite via:                                           │
│     a. QR code (display in app)                                 │
│     b. Copy link                                                │
│     c. AirDrop                                                  │
│     d. Share sheet                                              │
└─────────────────────────────────────────────────────────────────┘
```

**Tasks:**
- [ ] Enhance `CreateSwarmSheet` with settings configuration
- [ ] Implement QR code generation for invites
- [ ] Add share sheet integration
- [ ] Guide owner through inviting first member

---

## UI Components Needed

### 1. WelcomeView (First Launch)

```swift
struct WelcomeView: View {
  enum OnboardingPath {
    case solo
    case joinSwarm
    case createSwarm
  }
  
  var body: some View {
    VStack {
      // App logo + tagline
      // "Peel back the layers of your dev environment"
      
      // Three options:
      Button("Get Started Solo") { path = .solo }
      Button("Join a Swarm") { path = .joinSwarm }
      Button("Create a Swarm") { path = .createSwarm }
    }
  }
}
```

### 2. OnboardingChecklist

Displayed on dashboard until dismissed:

| Item | Description | Completed |
|------|-------------|-----------|
| ✅ Add a repository | Select your first repo | ☐ |
| ✅ Run a chain | Execute your first agent chain | ☐ |
| ✅ Index for RAG | Enable semantic search | ☐ |
| ✅ Connect MCP | Use Peel from VS Code/Claude | ☐ |
| ✅ Join a swarm | Collaborate with others | ☐ |

### 3. InvitePreviewView

Shows before accepting an invite:

```
┌─────────────────────────────────────────────────────┐
│  🎉 You're Invited!                                 │
│                                                     │
│  Chris's Home Swarm                                 │
│  Invited by: chris@example.com                      │
│                                                     │
│  Expires: Feb 1, 2026 at 3:00 PM                   │
│                                                     │
│  ┌─────────────────────────────────────────┐       │
│  │  Sign In with Apple to Join             │       │
│  └─────────────────────────────────────────┘       │
│                                                     │
│  After joining, you'll need approval from an admin │
└─────────────────────────────────────────────────────┘
```

### 4. InviteShareSheet (Enhanced)

```
┌─────────────────────────────────────────────────────┐
│  Invite to Chris's Home Swarm                       │
│                                                     │
│  ┌───────────┐                                     │
│  │  QR CODE  │   Scan with iPhone camera           │
│  │           │   or Peel app                       │
│  └───────────┘                                     │
│                                                     │
│  ─────────────── or ───────────────                │
│                                                     │
│  [ Copy Invite Link ]                              │
│  [ Share via AirDrop ]                             │
│  [ More Options... ]                               │
│                                                     │
│  ⚠️ Expires in 23 hours • Single use              │
└─────────────────────────────────────────────────────┘
```

---

## Technical Implementation

### Phase 1: URL Scheme & Invite Flow (Priority)

1. **Register URL scheme** in Info.plist (already done: `peel://`)
2. **Add URL handler** in PeelApp:

```swift
.onOpenURL { url in
  if url.scheme == "peel", url.host == "swarm" {
    handleSwarmURL(url)
  }
}

func handleSwarmURL(_ url: URL) {
  guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let swarmId = components.queryItems?.first(where: { $0.name == "s" })?.value,
        let inviteId = components.queryItems?.first(where: { $0.name == "i" })?.value,
        let token = components.queryItems?.first(where: { $0.name == "t" })?.value else {
    return
  }
  
  // Show invite preview
  pendingInvite = PendingInvite(swarmId: swarmId, inviteId: inviteId, token: token)
  showingInvitePreview = true
}
```

3. **Validate invite before showing preview**:
```swift
func validateInvite(swarmId: String, inviteId: String, token: String) async throws -> InviteInfo {
  // Check invite exists, not expired, not revoked, uses remaining
}
```

### Phase 2: Welcome Experience

1. **Add `hasCompletedOnboarding` to AppStorage**
2. **Show WelcomeView if false**
3. **Track checklist completion in SwiftData**

### Phase 3: Notifications

1. **Request notification permission** after sign-in
2. **Configure Firebase Cloud Messaging (FCM)**
3. **Notify when:**
   - Pending member approved
   - New pending member (for admins)
   - Task completed in swarm

---

## Migration for Existing Users

For users who update to a version with onboarding:

1. Check if user has existing data (repositories, chains run, etc.)
2. If yes → mark onboarding as "complete" automatically
3. Still show swarm features if not yet discovered

---

## Success Metrics

| Metric | Target |
|--------|--------|
| First chain run within 5 min of install | 60% |
| Invite acceptance rate | 80% |
| Time from invite → pending → approved | < 1 hour |
| Swarm creation after solo use | 20% within first week |

---

## Implementation Order

1. **Week 1: Invite Flow** (highest impact)
   - URL scheme handler
   - InvitePreviewView
   - AwaitingApprovalView

2. **Week 2: Onboarding Checklist**
   - WelcomeView
   - OnboardingChecklistView
   - Persistence

3. **Week 3: Enhanced Sharing**
   - QR code generation
   - Share sheet integration
   - AirDrop support

4. **Week 4: Notifications**
   - FCM setup
   - Push notification handling
   - In-app notification center

---

## Open Questions

1. **App Store vs Direct Download:** Do we need Universal Links for web-to-app flow?
2. **iOS Support:** Should onboarding work on iOS too, or Mac-only for now?
3. **Anonymous Invites:** Allow joining without Apple ID (with limited permissions)?
4. **Onboarding Skip:** Should users be able to skip the wizard entirely?

---

## Related Documents

- [FIRESTORE_SWARM_DESIGN.md](FIRESTORE_SWARM_DESIGN.md) — Security model & data structures
- [DISTRIBUTED_PEEL_DESIGN.md](DISTRIBUTED_PEEL_DESIGN.md) — Original distributed architecture
- [PRODUCT_MANUAL.md](../Docs/PRODUCT_MANUAL.md) — User documentation
