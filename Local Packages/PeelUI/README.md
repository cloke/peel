# PeelUI Helpers

## Consolidated Buttons & Confirmations (2026-01-24)

This folder includes reusable SwiftUI helpers for consistent action buttons and confirmation dialogs:

- `DestructiveActionButton` (ButtonHelpers.swift)
- `PrimaryActionButton` (ButtonHelpers.swift)
- `ConfirmAction` and `confirmAlert` / `confirmDialog` (Confirmations.swift)
- `RefreshToolbarItem` (ToolbarItems.swift)

### Usage Examples

```swift
// Destructive action
DestructiveActionButton {
  deleteItem()
} label: {
  Label("Delete", systemImage: "trash")
}

// Confirmation dialog
.confirmDialog(
  "Delete Template",
  isPresented: $showingDelete,
  confirmLabel: "Delete",
  confirmRole: .destructive,
  message: "This cannot be undone."
) {
  deleteTemplate()
}

// Toolbar refresh
.toolbar {
  RefreshToolbarItem(placement: .automatic) {
    Task { await reload() }
  }
}
```

### RAG Guidance Sources

These helpers align with existing patterns in:
- ViewState error handling (Local Packages/PeelUI/Sources/PeelUI/ViewState.swift)
- Shared toolbar patterns (Shared/CommonToolbarItems.swift)
