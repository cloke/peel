---
status: planning
created: 2026-01-05
updated: 2026-01-05
priority: high
parent-plan: AGENT_ORCHESTRATION_PLAN.md
tags:
  - swiftui
  - ui-ux
  - modernization
  - macos-26
  - ios-26
estimated-effort: 1-2 weeks
---

# SwiftUI UX Modernization Plan

## Overview

Kitchen Sync was built on macOS 13 with SwiftUI 3.0 (circa 2020-2021). This plan outlines modernizing the UI/UX to leverage modern SwiftUI features available in macOS 14+ and iOS 18+, taking advantage of the latest APIs and design patterns.

---

## Current State Analysis (To be completed by agent)

### Current SwiftUI Version & Patterns
- **Platform Targets:** macOS 26 (Tahoe), iOS 26
- **Original Development:** macOS 13 / SwiftUI 3.0 era
- **Current Issues:**
  - [ ] Audit existing views and identify outdated patterns
  - [ ] List deprecated APIs or workarounds that can be replaced
  - [ ] Identify inconsistencies between macOS and iOS implementations
  - [ ] Document current navigation patterns

### Existing Views to Audit
```
Shared/
├── KitchenSyncApp.swift          # App entry point
├── CommonToolbarItems.swift      # Toolbar components
├── Applications/
│   ├── Brew_RootView.swift       # Homebrew view
│   ├── Git_RootView.swift        # Git view
│   └── Github_RootView.swift     # GitHub view (primary)
├── Extensions/
│   └── Color.swift               # Color utilities
└── Views/
    ├── SettingsView.swift        # App settings
    └── TaskDebugWindowView.swift # Debug window

macOS/ContentView.swift            # macOS-specific wrapper
iOS/ContentView.swift              # iOS-specific wrapper

Local Packages/
├── Github/Sources/Github/         # Many views mixed with models
├── GithubUI/Sources/GithubUI/     # Additional GitHub views
├── Brew/Sources/Brew/             # Brew views
└── Git/Sources/Git/               # Git views
```

---

## Modern SwiftUI Features to Leverage

### macOS 26 / iOS 26 Features (Research Phase)
- [ ] **Research:** New SwiftUI 6.0 APIs available
- [ ] **Research:** New navigation patterns (NavigationStack improvements)
- [ ] **Research:** New layout containers and modifiers
- [ ] **Research:** Improved Form and List APIs
- [ ] **Research:** New animation and transition APIs
- [ ] **Research:** Better macOS/iOS API parity

### Known Modern Patterns to Adopt
- [ ] **NavigationStack** - Replace old NavigationView patterns
- [ ] **Observable macro** - Replace ObservableObject where appropriate
- [ ] **SwiftData** - Consider for local data persistence (vs @AppStorage)
- [ ] **New Layout APIs** - Grid, FlowLayout, etc.
- [ ] **Sensory Feedback** - Modern haptics/feedback
- [ ] **Swift Charts** - If any data visualization needed
- [ ] **New Picker styles** - Modern selection UI
- [ ] **Improved Toolbar API** - Better toolbar customization

---

## Modernization Goals

### 1. Consistent Cross-Platform Experience
**Current:** macOS uses NavigationSplitView, iOS simplified
**Goal:** Unified experience with platform-specific enhancements

- [ ] Audit navigation differences between macOS and iOS
- [ ] Determine optimal navigation pattern for both platforms
- [ ] Implement consistent navigation structure
- [ ] Add platform-specific flourishes where appropriate

### 2. Modern Visual Design
**Current:** Basic SwiftUI 3.0 aesthetics
**Goal:** Modern, polished UI leveraging latest design patterns

- [ ] Audit current visual hierarchy
- [ ] Identify areas for improved spacing, typography, colors
- [ ] Add subtle animations and transitions
- [ ] Improve empty states and loading indicators
- [ ] Add proper error states with retry actions

### 3. Better Data Flow
**Current:** Mix of @AppStorage, @Published, callbacks
**Goal:** Modern, predictable data flow

- [ ] Audit current state management patterns
- [ ] Consider Observable macro for ViewModels
- [ ] Consider SwiftData for structured local data
- [ ] Unify token/credential storage approach
- [ ] Implement proper loading/error states

### 4. Enhanced GitHub Integration UX
**Current:** Basic list views, minimal interaction
**Goal:** Rich, interactive GitHub experience

- [ ] Modern PR review interface
- [ ] Better organization/repository browsing
- [ ] Inline code viewing
- [ ] Quick actions (approve, comment, merge)
- [ ] Rich markdown rendering for PR descriptions
- [ ] Better diff viewing

---

## Implementation Phases

### Phase 1: Research & Audit (Agent Task)
**Outcome:** Detailed analysis document

- [ ] Analyze all existing views and their patterns
- [ ] Research available SwiftUI APIs for macOS 26 / iOS 26
- [ ] Identify quick wins vs major refactors
- [ ] Document current navigation flow
- [ ] Screenshot current UI for before/after comparison
- [ ] Prioritize modernization tasks

### Phase 2: Foundation Updates
**Outcome:** Modern base architecture

- [ ] Update to NavigationStack patterns
- [ ] Implement modern Observable patterns
- [ ] Create reusable modern components library
- [ ] Establish consistent color/typography system
- [ ] Create standard loading/error state components

### Phase 3: View-by-View Modernization
**Outcome:** Polished, modern UI

- [ ] Modernize Github_RootView (primary view)
- [ ] Update organization/repository browsing
- [ ] Modernize PR list and detail views
- [ ] Update settings view
- [ ] Polish toolbar and navigation
- [ ] Update Brew view (if keeping)
- [ ] Update Git view (if keeping)

### Phase 4: Polish & Platform Parity
**Outcome:** Consistent cross-platform experience

- [ ] Test and refine iOS experience
- [ ] Add platform-specific enhancements
- [ ] Performance optimization
- [ ] Animation polish
- [ ] Accessibility audit
- [ ] Dark mode refinement

---

## Success Criteria

- [ ] Modern, polished visual design
- [ ] Consistent experience on macOS and iOS
- [ ] Leverages latest SwiftUI features
- [ ] Better performance and responsiveness
- [ ] Improved user flows for common tasks
- [ ] Reduced code duplication
- [ ] Better maintainability
- [ ] Positive user feedback

---

## Next Steps for Agent

**Primary Task:** Research and create detailed audit

1. **Explore the codebase:**
   - Read through all view files
   - Document current patterns and architectures
   - Identify SwiftUI version indicators (NavigationView vs Stack, etc.)
   - Note any workarounds or hacks

2. **Research modern SwiftUI:**
   - Research SwiftUI 6.0 features available on macOS 26 / iOS 26
   - Identify features that would benefit Kitchen Sync
   - Find examples of modern SwiftUI apps for inspiration

3. **Create detailed recommendations:**
   - Specific API replacements
   - New patterns to adopt
   - Quick wins vs long-term refactors
   - Estimated effort for each change

4. **Update this plan:**
   - Fill in the "Current State Analysis" section
   - Add specific tasks to implementation phases
   - Provide code examples of before/after patterns
   - Create a prioritized task list

---

## Resources

- [Apple SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [What's New in SwiftUI (WWDC sessions)](https://developer.apple.com/wwdc/)
- [SwiftUI by Example](https://www.hackingwithswift.com/quick-start/swiftui)
- macOS Human Interface Guidelines
- iOS Human Interface Guidelines

---

## Progress Tracking

### Session 1: January 5, 2026 (3 hours) ✅ COMPLETE

**What We Accomplished:**
1. ✅ **Deep Dive Audit** - Analyzed 109 Swift files, identified all issues
2. ✅ **Package Consolidation:**
   - Deleted CrunchyCommon package (migrated to Shared/Extensions)
   - Merged GithubUI into Github package
   - **Result:** 5 packages → 3 packages (40% reduction)
3. ✅ **Bug Fixes:**
   - Fixed Git tool crash (URL(string:) → URL(fileURLWithPath:))
   - Fixed tool switching crash (removed file:// prefix)
4. ✅ **@Observable Migration:**
   - Converted Github.ViewModel (ObservableObject → @Observable + @MainActor)
   - Removed ALL Combine code from Github package
   - Updated 7 files to use modern patterns
   - **Removed 18 lines of Combine boilerplate**
5. ✅ **Documentation:**
   - Created MODERNIZATION_SUMMARY.md (executive summary)
   - Created .github/copilot-instructions.md (Swift 6 best practices)

**Commits:** 5 (8f0c28e, ca2d2c0, 3a8156e, 8f00117, beb1313)  
**Build:** ✅ SUCCESS  
**Files Changed:** ~33 total

**Known Issues:**
- 🐛 PR tab rendering bug - **may be fixed** by @Observable conversion (needs testing tomorrow)

**Testing Needed:**
- [ ] Test GitHub login/logout
- [ ] Test organization browsing
- [ ] **Test if PR tab renders correctly now** (most important!)
- [ ] Test Personal view filters ("My Requests" / "All")
- [ ] Verify no regressions

---

### Session 2: January 6, 2026 (1 hour) ✅ COMPLETE

**What We Accomplished:**
1. ✅ **Keychain Security Migration:**
   - Created `KeychainService` actor for secure token storage (138 lines)
   - Migrated GitHub OAuth token from `@AppStorage` → Keychain
   - Updated `Network.swift` to use async keychain access
   - Made `headers` and `hasToken` async properties
   - Simplified `ViewModel` by removing duplicate token management
2. ✅ **OAuth UX Fix:**
   - Fixed OAuth callback opening new window
   - Added `.handlesExternalEvents(preferring:allowing:)` to activate existing window
   - Cleaned up verbose debug logging

**Commits:** 3 (8de44f6, 37e6535, 8dbe62a) - **Merged to main** ✅  
**Build:** ✅ SUCCESS  
**Files Changed:** 4 files (+211/-54 lines)

**Security Impact:** ⭐ **HIGH** - OAuth tokens now properly secured in Keychain instead of UserDefaults

**Testing Needed:**
- [ ] Test GitHub login flow
- [ ] Verify OAuth returns to existing window (not new window)
- [ ] Test logout and verify token is deleted from Keychain
- [ ] Test app restart - token should persist

---

## Next Session Priorities (Session 3)

### Option A: Quick Wins - Clean Up Warnings ⭐ RECOMMENDED START
**Fix deprecation warnings** (30 minutes)
- Fix `onChange(of:perform:)` deprecation in OrganizationRepositoryView.swift
- Fix NavigationLink deprecation in BranchListView.swift
- **Impact:** Low | **Risk:** Low | **Time:** 30 minutes
- **Why start here:** Clean slate before bigger refactors

### Option B: Continue ViewModel Modernization
**Convert Git.ViewModel to @Observable** (210 lines, more complex)
- Remove heavy Combine usage (PassthroughSubject, sink, etc.)
- Fix manual DispatchQueue.main.async calls
- Modernize Repository class as well
- **Impact:** Medium-High | **Risk:** Medium | **Time:** 2-3 hours

### Option C: Navigation Modernization (Big Task)
**Update NavigationView → NavigationStack** (7 files)
- Higher risk of breaking things
- Recommend doing after ViewModels are modernized
- **Impact:** High | **Risk:** High | **Time:** 3-4 hours

**Recommendation:** Start Session 3 with **Option A (warnings)**, then move to **Option B (Git.ViewModel)**

---

## Resources

- [Apple SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/)
- [@Observable Documentation](https://developer.apple.com/documentation/observation)
- [Navigation Stack Guide](https://developer.apple.com/documentation/swiftui/navigationstack)
- Project plans in `/Plans/`

---

## Notes

- ✅ Modernization is progressing well - 40% package reduction on day 1
- ✅ @Observable conversion was smooth, may have fixed lifecycle bugs
- ⚠️ Need to decide on Brew package fate (keep or delete)
- 📝 Git.ViewModel is next big refactor (heavy Combine usage)
- 🎯 Focus remains on GitHub tool per user request

---

**End of Session 1 - January 5, 2026**
