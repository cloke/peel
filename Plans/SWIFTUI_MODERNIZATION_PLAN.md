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
  - ios-18
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

## Notes

- Keep backward compatibility considerations minimal (targeting latest OS)
- Focus on developer experience and maintainability
- Prioritize features that improve user workflows
- Consider accessibility from the start
- Test on both macOS and iOS throughout development
