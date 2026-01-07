# SwiftData Integration Plan

**Date:** January 7, 2026  
**Status:** 🟡 **PLANNING**  
**Priority:** Medium  
**Goal:** Replace @AppStorage with SwiftData for better persistence and iCloud sync

---

## Overview

Currently, Kitchen Sync uses:
- **@AppStorage + JSON encoding** for Git repository list persistence
- **Keychain** for GitHub OAuth tokens (correctly)
- **No persistence** for GitHub data (fetched fresh each time)

SwiftData would provide:
- Type-safe persistence
- Automatic iCloud sync (CloudKit integration)
- Relationships between models
- Query/filter capabilities
- Undo/redo support

---

## Current State Analysis

### What's Being Persisted Now

| Data | Storage Method | Location |
|------|----------------|----------|
| Git repositories list | @AppStorage + JSON | UserDefaults |
| Selected repository | @AppStorage + JSON | UserDefaults |
| Current tool selection | @AppStorage | UserDefaults |
| GitHub OAuth token | Keychain | Keychain (correct!) |
| GitHub user data | Not persisted | Memory only |
| Worktrees | Not persisted | Fetched from git |

### What Should Be Persisted

| Data | Should Persist? | iCloud Sync? |
|------|-----------------|--------------|
| Git repositories list | ✅ Yes | ✅ Yes |
| Selected repository | ✅ Yes | ❌ No (device-specific) |
| Current tool | ✅ Yes | ❌ No (device-specific) |
| GitHub OAuth token | ✅ Already (Keychain) | ❌ No (security) |
| Favorite repositories | ✅ Yes (new feature) | ✅ Yes |
| Recent PRs viewed | ✅ Yes (new feature) | ✅ Yes |
| Worktrees | ❌ No (git manages) | N/A |

---

## Proposed SwiftData Models

### Core Models

```swift
import SwiftData

@Model
final class GitRepository {
  @Attribute(.unique) var path: String
  var name: String
  var lastAccessed: Date
  var isFavorite: Bool
  
  // Relationships
  @Relationship(deleteRule: .cascade)
  var worktrees: [SavedWorktree]
  
  init(path: String, name: String) {
    self.path = path
    self.name = name
    self.lastAccessed = Date()
    self.isFavorite = false
  }
}

@Model
final class SavedWorktree {
  var path: String
  var branch: String
  var createdAt: Date
  var note: String?
  
  @Relationship(inverse: \GitRepository.worktrees)
  var repository: GitRepository?
  
  init(path: String, branch: String) {
    self.path = path
    self.branch = branch
    self.createdAt = Date()
  }
}

@Model
final class GitHubFavorite {
  @Attribute(.unique) var repoId: Int
  var repoName: String
  var ownerLogin: String
  var addedAt: Date
  
  init(repoId: Int, repoName: String, ownerLogin: String) {
    self.repoId = repoId
    self.repoName = repoName
    self.ownerLogin = ownerLogin
    self.addedAt = Date()
  }
}

@Model
final class RecentPullRequest {
  @Attribute(.unique) var prId: Int
  var prNumber: Int
  var title: String
  var repoName: String
  var ownerLogin: String
  var viewedAt: Date
  
  init(prId: Int, prNumber: Int, title: String, repoName: String, ownerLogin: String) {
    self.prId = prId
    self.prNumber = prNumber
    self.title = title
    self.repoName = repoName
    self.ownerLogin = ownerLogin
    self.viewedAt = Date()
  }
}

// Device-specific settings (not synced to iCloud)
@Model
final class AppSettings {
  @Attribute(.unique) var deviceId: String
  var currentTool: String
  var selectedRepositoryPath: String?
  var lastUsed: Date
  
  init(deviceId: String = UUID().uuidString) {
    self.deviceId = deviceId
    self.currentTool = "brew"
    self.lastUsed = Date()
  }
}
```

### Container Setup

```swift
import SwiftData

@main
struct KitchenSyncApp: App {
  var sharedModelContainer: ModelContainer = {
    let schema = Schema([
      GitRepository.self,
      SavedWorktree.self,
      GitHubFavorite.self,
      RecentPullRequest.self,
      AppSettings.self,
    ])
    
    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .automatic  // Enables iCloud sync
    )
    
    do {
      return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }
  }()
  
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .modelContainer(sharedModelContainer)
  }
}
```

---

## Implementation Phases

### Phase 1: Setup & Git Repository Migration (1-2 hours)
- [ ] Add SwiftData to project
- [ ] Create `GitRepository` model
- [ ] Create `SavedWorktree` model  
- [ ] Migrate existing @AppStorage data to SwiftData
- [ ] Update Git ViewModel to use SwiftData
- [ ] Remove old @AppStorage code

### Phase 2: App Settings (30 min)
- [ ] Create `AppSettings` model for device-specific settings
- [ ] Migrate current tool selection
- [ ] Keep @AppStorage only for truly simple preferences

### Phase 3: GitHub Favorites (1 hour)
- [ ] Create `GitHubFavorite` model
- [ ] Add "favorite" button to repository views
- [ ] Create favorites view/section
- [ ] Sync favorites via iCloud

### Phase 4: Recent Items (1 hour)
- [ ] Create `RecentPullRequest` model
- [ ] Track recently viewed PRs
- [ ] Show recent PRs in Personal view
- [ ] Auto-cleanup old entries (> 30 days)

### Phase 5: iCloud Sync Testing (1-2 hours)
- [ ] Enable CloudKit container in Xcode
- [ ] Test sync between devices
- [ ] Handle merge conflicts
- [ ] Add sync status indicator

---

## Benefits

### Immediate Benefits
1. **Type safety** - No more JSON encoding/decoding boilerplate
2. **Automatic persistence** - Models save automatically
3. **Query support** - Filter and sort with predicates
4. **Relationships** - Link repositories to worktrees

### Future Benefits (with iCloud)
1. **Cross-device sync** - Repository list syncs between Macs
2. **Favorites everywhere** - Star a repo on one Mac, see it on another
3. **Recent PRs** - Continue where you left off on any device
4. **Backup** - Data backed up to iCloud automatically

---

## Migration Strategy

### Step 1: Non-Breaking Addition
Add SwiftData models alongside existing @AppStorage. Both work during transition.

### Step 2: Migration Code
```swift
func migrateFromAppStorage(modelContext: ModelContext) {
  // Check if migration needed
  let fetchDescriptor = FetchDescriptor<GitRepository>()
  guard (try? modelContext.fetchCount(fetchDescriptor)) == 0 else { return }
  
  // Load from @AppStorage
  let oldData = UserDefaults.standard.data(forKey: "repositories") ?? Data()
  guard let oldRepos = try? JSONDecoder().decode([OldRepository].self, from: oldData) else { return }
  
  // Create new models
  for old in oldRepos {
    let new = GitRepository(path: old.path, name: old.name)
    modelContext.insert(new)
  }
  
  try? modelContext.save()
  
  // Clear old data (optional, or keep as backup)
  // UserDefaults.standard.removeObject(forKey: "repositories")
}
```

### Step 3: Remove Old Code
Once migration is verified, remove @AppStorage code.

---

## iCloud Setup Requirements

1. **Apple Developer Account** with iCloud capability
2. **CloudKit Container** - Create in Apple Developer portal
3. **Xcode Capabilities:**
   - iCloud (CloudKit)
   - Background Modes (Remote notifications)
4. **Entitlements:**
   ```xml
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array>
     <string>iCloud.com.yourcompany.kitchensync</string>
   </array>
   ```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Data loss during migration | Keep @AppStorage as backup for 2 releases |
| iCloud sync conflicts | Use simple merge strategy (last-write-wins for now) |
| CloudKit quota limits | Only sync small metadata, not full GitHub responses |
| Offline mode | SwiftData works offline, syncs when connected |

---

## Decision: Should We Do This?

### Do SwiftData Now If:
- ✅ You want favorites/recent items features
- ✅ You plan to use the app on multiple Macs
- ✅ You want better data architecture for future features
- ✅ You're okay with some setup time

### Keep @AppStorage If:
- ❌ Current persistence is sufficient
- ❌ iCloud sync isn't needed
- ❌ Want to minimize changes

### Recommendation

**Start with Phase 1 only** (Git repository migration). This:
- Modernizes the data layer
- Prepares for future iCloud sync
- Doesn't require CloudKit setup yet
- Can stop there if sufficient

iCloud sync (Phase 5) can be added later when you have multiple devices or want the features.

---

## Next Steps

1. Decide: Do Phase 1 now or defer?
2. If yes, I'll implement the SwiftData models and migration
3. iCloud can be enabled later with minimal code changes
