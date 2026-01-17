# VM Isolation Audit Plan

## Goal
Stabilize Linux VM launch and document a minimal, reliable baseline before expanding features.

## Current Known Good
- VM starts without UI hangs when console streaming is disabled.
- VM start/stop must run on the main actor.
- Debian netboot kernel/initramfs download works (arm64).

## Audit Scope
1. VMIsolationService
   - ✅ Initialization flow
   - ✅ Linux setup paths (kernel/initramfs downloads, decompression)
   - ✅ VM configuration (boot loader, platform, devices)
   - ✅ Start/stop lifecycle
   - ✅ Console output handling
2. VMIsolationView
   - ✅ UI triggers for start/stop
   - ✅ Task execution context (main actor)
   - ✅ Error surfacing and status updates
3. Supporting services
   - ✅ Entitlements and sandbox expectations
4. CLI VMTest harness
   - ✅ Baseline harness and entitlements reviewed

## Progress Log
- 2026-01-17: Completed initial code audit of VMIsolationService, VMIsolationView, entitlements, and VMTest.

## Findings Log (fill during audit)
- [x] Kernel format warnings (PE/EFI vs raw Image)
   - Kernel header check warns on PE/EFI (MZ) and logs in both VM service + VMTest.
- [x] VM configuration assumptions (devices on/off)
   - Minimal Linux config attaches serial + entropy only; disk/network/memory balloon are disabled via toggles.
   - This is good for boot stabilization but prevents meaningful workloads until toggles are enabled.
- [x] Thread/actor requirements (main actor)
   - VM service is `@MainActor`. View uses `Task { @MainActor in ... }` for start/stop.
- [x] UI update throttling needs
   - Console output reader is present with 0.25s/4KB throttle, but disabled by default to avoid UI hangs.
- [x] Error handling consistency
   - Start errors are wrapped into `VMError.vmCreationFailed` with details; delegate logs errors but does not update service state.

## Additional Notes
- UI copy says “Fedora kernel + initramfs” but Linux setup now downloads Debian netboot. Update copy for consistency.
- `downloadFirstAvailable` still calls `extractFedoraRelease` even for Debian URLs (release unused today).
- If the VM stops unexpectedly, `runningLinuxVM` remains set because delegate does not clear state.

## Image Selection Notes (for GH CLI isolation)
- **Current baseline**: Debian netboot kernel + initramfs (bookworm, arm64). Works with `VZLinuxBootLoader` when initramfs is raw CPIO.
- **Alpine**: Viable if you use the **netboot** kernel + initramfs (raw Image + CPIO). Alpine’s standard rootfs is minimal and fast.
   - GH CLI on Alpine requires `apk add github-cli` (community repo) and network enabled.
   - If packages or tooling assume glibc, Alpine may need a compatibility layer; Debian avoids that.
- **Goal-oriented recommendation**:
   - For fastest success with GH CLI + Copilot: **Debian netboot** → add disk + network, then install `gh` inside the VM.
   - For smallest footprint: **Alpine netboot** → verify `github-cli` package availability and musl compatibility.

## Next Actions (image decision)
- [ ] Decide on default Linux distro (Debian vs Alpine) for the isolation baseline.
- [ ] If Alpine is chosen: add Alpine netboot URLs and expected package install steps to VM setup.
- [ ] Enable disk + network toggles for a “useful” VM profile once baseline boot is stable.

## Outcomes
- Minimal, documented Linux VM boot path
- Optional feature toggles (disk/network/console)
- Clear next steps for “right” implementation
