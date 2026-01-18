# VM Console Output & Boot Plan

**Date:** January 17, 2026
**Status:** In Progress (Booting to Initramfs Shell)
**Owner:** VM Isolation

## Current Status
- **Boot State:** ✅ Kernel & Initramfs load.
- **Console UI:** ✅ Visible in `VMIsolationView`. `ScrollView` implementation is stable.
- **Kernel:** ✅ Alpine `virt` kernel (patched via `extractEmbeddedKernel`).
- **Issue:** ❌ Boot fails at mount stage: `Mounting boot media: failed`.
- **Environment:** Dropped into `initramfs emergency recovery shell`.
- **Input:** Works, but shell echoes escape codes (`[6n`).

## Critical Prevention: "Circle of Breaking Images"
**Rule:** VZLinuxBootLoader **requires** a raw uncompressed Image. Alpine `vmlinuz` is EFI PE.
- **Solution:** We use `extractEmbeddedKernel` (gzip scan) in `VMIsolationService.swift`.
- **Warning:** Do NOT revert to standard downloads without this extraction.

## Next Session Goals
1.  **Fix Mount Failure:** Pass `alpine_repo` or configure rootfs for diskless/netboot.
2.  **Piping:** Implement escape code stripping for cleaner UI.
3.  **Cleanup:** Stabilize kernel args.

## Findings & Failed Attempts (Archive)
1.  **Debian/Fedora:** Abandoned for Alpine (lighter/faster).
2.  **Concurrency Fix (✅ Fixed):** Serial/Console separation.
3.  **UI Data Binding (✅ Fixed):** Fixed `constant` binding bug.

## Current Strategy: Fedora Pivot
We have switched the Guest VM image from **Debian Netboot** to **Fedora 39 Server** (ARM64) which has better out-of-the-box support for virtio consoles on Apple Silicon.

### Action Plan
1.  **Update `VMIsolationService.swift`** (✅ Done):
    - Changed download URLs to **Fedora 39 Server**.
    - Added auto-cleanup logic to delete old Debian files.
2.  **Reset VM** (⏳ Pending User Action): Run the app to force the download/reset cycle.
3.  **Test** (⏳ Pending): Boot and listen for the "Hello" banner.

## Success Criteria
- Valid text output ("Welcome to Linux", "Booting...", etc.) in the debug console.
