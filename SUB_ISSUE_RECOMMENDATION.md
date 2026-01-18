# Sub-Issue Recommendation for #9

## Issue #9 Progress

The following tasks from issue #9 "Polish Linux VM experience" have been completed:

✅ **Strip ANSI escape codes from console output**  
✅ **Fix UI label inconsistencies (Alpine vs Debian/Fedora)**  
✅ **Clear runningLinuxVM on unexpected VM stop** (already working)  
✅ **Document rootfs setup**

## Recommended Sub-Issue

The remaining "quick-start presets" feature is substantial enough to warrant its own issue.

### Suggested GitHub Issue

**Title:** Add quick-start presets for Linux VM

**Labels:** `enhancement`, `vm-isolation`

**Body:**
```markdown
## Description

Add preset configurations for common Linux VM use cases to simplify setup and reduce manual configuration.

## Background

Issue #9 polished the basic VM experience. This enhancement adds user-friendly presets that auto-configure the VM for different scenarios.

## Presets to Implement

### 1. Minimal (Default)
- **Config**: No network, no disk, initramfs only
- **Use Case**: Basic boot testing and diagnostics
- **Boot Time**: ~3s
- **Disk Usage**: ~50MB

### 2. Development
- **Config**: Network enabled (NAT), Alpine netboot
- **Use Case**: Package installation, internet-connected testing
- **Boot Time**: ~5s (includes package download)
- **Disk Usage**: ~100MB (cached packages)
- **Command Line**: `console=hvc0 alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v3.21/main modloop=http://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot/modloop-virt`

### 3. Build Server
- **Config**: Network + persistent disk image with full rootfs
- **Use Case**: Compilation, long-running tasks, agent execution
- **Boot Time**: ~4s (disk-based)
- **Disk Usage**: 1-2GB (full Alpine install)
- **Features**: Package manager, persistent storage, full Linux environment

## Implementation Tasks

- [ ] Define `VMPreset` enum with three preset types
- [ ] Create `VMConfigurationBuilder` that applies preset settings
- [ ] Add preset selector to VMIsolationDashboardView UI
- [ ] Update `createMinimalLinuxVMConfiguration()` to accept preset parameter
- [ ] Auto-configure network attachment based on preset
- [ ] Auto-configure disk attachment based on preset
- [ ] Generate appropriate kernel command lines per preset
- [ ] Add preset descriptions and recommendations in UI
- [ ] Update documentation with preset usage examples

## UI Mockup

```swift
// Add to VMIsolationDashboardView
Picker("VM Preset", selection: $selectedPreset) {
  Text("Minimal (Testing)").tag(VMPreset.minimal)
  Text("Development (Network)").tag(VMPreset.development)
  Text("Build Server (Full)").tag(VMPreset.buildServer)
}
.pickerStyle(.segmented)
```

## Related Issues

- Parent: #9 (Polish Linux VM experience)
- See: `Plans/VM_ISOLATION_PLAN.md` for rootfs setup details

## References

- `Shared/AgentOrchestration/VMIsolationService.swift` - Main VM service
- `Shared/AgentOrchestration/VMIsolationView.swift` - UI dashboard
- `Plans/VM_ISOLATION_PLAN.md` - VM isolation architecture and setup guide
```

## How to Create the Issue

Run the following command:

```bash
gh issue create --repo cloke/peel \
  --title "Add quick-start presets for Linux VM" \
  --label "enhancement,vm-isolation" \
  --body-file SUB_ISSUE_RECOMMENDATION.md
```

Or create it manually via the GitHub web UI using the content above.

## Why a Separate Issue?

The preset feature involves:
- New enum types and data structures
- UI components (picker, descriptions)
- Configuration builders
- Documentation updates
- Testing across preset types

This is significant enough to deserve its own planning, implementation, and review cycle rather than being bundled with the polish tasks.
