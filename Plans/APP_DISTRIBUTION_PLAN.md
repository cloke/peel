---
title: Peel Distribution & Auto-Update Plan
status: draft
tags:
  - distribution
  - auto-update
  - ci
updated: 2026-03-10
audience:
  - developer
  - ai-agent
---

# Peel Distribution & Auto-Update Plan

## Goals
1. **Low-cost distribution** — Host compiled builds as GitHub Release assets (free for public repos)
2. **In-app auto-update** — Users get prompted when a new version is available, can update with one click
3. **Build traceability** — Every build carries its git commit hash, visible in About

---

## 1. GitHub Releases Distribution

### Strategy
Use GitHub Releases on the `cloke/peel` repo. Each release is a git tag (`v1.x.x`) with a zipped `.app` bundle attached as an asset. This is free for public repos with generous bandwidth (no CDN costs).

### Release Artifact Format
```
Peel-v1.2.0-macos.zip
├── Peel.app/
```

- Zip the `.app` bundle (preserves code signature, symlinks, extended attributes)
- Use `ditto -c -k --keepParent` (not `zip`) to preserve macOS metadata
- Name convention: `Peel-v{version}-macos.zip`

### Release Script (`Tools/release.sh`)
```bash
#!/bin/zsh
# Usage: Tools/release.sh v1.2.0

VERSION="$1"
# 1. Build Release configuration
# 2. Zip with ditto
# 3. Create GitHub release with gh CLI
# 4. Upload zip as release asset
```

**Implementation tasks:**
- [ ] Create `Tools/release.sh` that builds Release, zips, and uploads
- [ ] Add code signing (Developer ID) for Gatekeeper — or instruct users to allow in System Settings
- [ ] Consider notarization (optional for now, required for smooth UX)
- [ ] Add `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` bump logic

### Branch vs Tag vs Release
| Option | Pros | Cons |
|--------|------|------|
| **Git tag + GitHub Release** | Clean history, semantic versioning, asset hosting | Need to create release manually or script it |
| **Dedicated branch** | Simple `git pull` update | Pollutes branch list, harder to version |
| **Tag only** | Lightest | No asset hosting |

**Decision: GitHub Releases (tag + assets).** Best balance of simplicity and functionality.

### Code Signing & Notarization

For initial distribution (developer builds, swarm workers):
- **Ad-hoc signing** is fine — same trust model as today
- Users right-click > Open on first launch

For public distribution:
- **Developer ID Application** certificate required
- **Notarization** via `xcrun notarytool` eliminates Gatekeeper warnings
- Can be added later without changing the distribution mechanism

---

## 2. In-App Auto-Update

### Design Principles
- No external framework dependencies (no Sparkle/WinSparkle)
- Use GitHub Releases API directly (already have GitHub API infrastructure)
- Minimal — check, download, replace, relaunch
- macOS only (iOS updates go through TestFlight/App Store)

### Architecture

```
AppUpdateService (actor)
├── checkForUpdate() → UpdateInfo?        // GitHub API: latest release
├── downloadUpdate(UpdateInfo) → URL      // Download zip to tmp/
├── installUpdate(URL) → Bool             // Replace .app, relaunch
└── UpdateInfo
    ├── version: String
    ├── commitHash: String
    ├── downloadURL: URL
    ├── releaseNotes: String
    └── publishedAt: Date
```

### Update Flow
1. **Check** — On app launch (+ manual "Check for Updates"), call GitHub Releases API:
   `GET /repos/cloke/peel/releases/latest`
2. **Compare** — Compare remote `tag_name` against local `CFBundleShortVersionString`.
   Also compare `PeelGitCommitHash` for same-version rebuild detection.
3. **Prompt** — Show native alert with release notes, "Update Now" / "Later" / "Skip This Version"
4. **Download** — Stream the zip asset to `tmp/Peel-update.zip`
5. **Install** — 
   a. Unzip to a temp location
   b. Verify the new `.app` (code signature, basic sanity)
   c. Move current app to trash (or `.bak`)
   d. Move new app into place
   e. Relaunch via `NSWorkspace` or a helper script
6. **Cleanup** — Delete downloaded zip and backup on next launch

### Update Check Frequency
- On launch: if last check was > 24 hours ago
- Manual: "Check for Updates" menu item (always checks)
- Configurable in Settings (daily / weekly / never)

### Security Considerations
- Always verify the download URL points to `github.com/cloke/peel/releases/`
- Verify zip integrity (size matches API response)
- Future: verify code signature of downloaded app matches expected Developer ID
- Never auto-install without user confirmation

### Menu Integration
Add to the app menu:
```
Peel
├── About Peel          (existing — now shows commit hash)
├── Check for Updates…  (NEW)
├── ─────────────────
├── Settings…
```

### UI States
| State | Display |
|-------|---------|
| Checking | "Checking for updates…" (spinner) |
| Up to date | "You're running the latest version." |
| Update available | "Peel v1.3.0 is available (you have v1.2.0)" + release notes + buttons |
| Downloading | Progress bar with percentage |
| Installing | "Installing update…" (indeterminate) |
| Error | "Update check failed: {error}" with retry |

---

## 3. Build Traceability (✅ Implemented)

### What's Done
- `PeelGitCommitHash` key added to both macOS and iOS Info.plist files
- "Stamp Git Commit Hash" build phase runs after Resources, writes the short hash into the built plist via `PlistBuddy`
- About panel now shows: `1.0 (13) · abc1234`

### How It Works
1. Source Info.plist has `<key>PeelGitCommitHash</key><string>dev</string>` as placeholder
2. Xcode build phase runs `git rev-parse --short HEAD` and stamps the built copy
3. Source plist stays unchanged (no dirty working tree from builds)
4. `Bundle.main.object(forInfoDictionaryKey: "PeelGitCommitHash")` reads it at runtime

---

## 4. Implementation Phases

### Phase A: Release Infrastructure ✅
- [x] Create `Tools/release.sh` — builds Release, zips with `ditto`, creates GitHub Release via `gh`
- [x] Add notarization support (`--notarize` flag, credential setup docs)
- [x] Add auto-generated release notes from git log
- [x] SHA-256 checksum in release notes
- [x] Version bumping in plists
- [x] Test zip creation (50 MB artifact, ditto preserves metadata)
- [x] Document release process in `Docs/guides/RELEASING.md`

### Phase B: Auto-Update Service ✅
- [x] Create `Shared/Services/AppUpdateService.swift` — actor that checks GitHub Releases API
- [x] `UpdateInfo` model with version comparison logic
- [x] "Check for Updates…" menu item in PeelApp.swift
- [x] Update prompt UI with "Update Now" / "View Release" / "Skip This Version"
- [x] Streaming download with progress reporting
- [x] Install: unzip via ditto, backup current app, replace, relaunch
- [x] URL validation (only github.com / githubusercontent.com)
- [x] Size verification on download
- [x] Bundle ID verification on install

### Phase C: Polish ✅
- [x] Update check frequency setting (Daily / Weekly / Never) in Settings > About
- [x] "Skip This Version" persistence
- [x] Progress UI for downloads (HUD panel with progress bar)
- [x] Version + commit hash shown in Settings > About tab
- [x] Automatic update check on launch (respects frequency setting)
- [x] "Check Now" button in Settings with last-checked timestamp

### Phase D: CI (future)
- [ ] GitHub Actions workflow to build + create release on tag push
- [ ] Automated notarization in CI
- [ ] Homebrew Cask formula

---

## 5. Version Scheme

```
CFBundleShortVersionString: 1.2.0       (marketing version)
CFBundleVersion:            42           (build number, auto-increment)
PeelGitCommitHash:          abc1234     (git short SHA, stamped at build)
Git tag:                    v1.2.0      (matches marketing version)
```

- Bump marketing version for each release
- Build number increments automatically (or per-release)
- Git hash provides exact commit traceability

---

## 6. Comparison with Alternatives

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **GitHub Releases** | Free, built-in, works with `gh` CLI | No delta updates | ✅ Use this |
| **Sparkle** | Mature, DSA signing, delta updates | External dependency, XML appcast | ❌ Overkill for now |
| **App Store** | Best UX, automatic updates | Review process, sandboxing limits MCP/git/brew | ❌ Not viable |
| **Homebrew Cask** | Easy install/update | Need to maintain cask formula | 🟡 Consider later |
| **S3 / CloudFront** | Full control | Costs money | ❌ Defeats the goal |

---

## References
- [GitHub Releases API](https://docs.github.com/en/rest/releases/releases)
- [ditto man page](https://ss64.com/mac/ditto.html) — preserves macOS metadata in zips
- [notarytool](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — Apple notarization
