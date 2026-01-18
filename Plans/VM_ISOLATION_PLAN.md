# VM Isolation Plan

**Updated:** January 18, 2026  
**Status:** Linux VM working (boots to CLI), macOS VM not yet  
**Priority:** Low (future feature)

---

## Current State

- ✅ Linux VM boots to command line
- ✅ Kernel + initramfs download works
- ✅ VZLinuxBootLoader with extracted raw kernel
- ⚠️ Console output shows ANSI escape codes (needs stripping)
- ⚠️ UI labels say "Fedora" but downloads Alpine/Debian
- ❌ macOS VM not working yet

---

## Known Issues

1. **Mount Failure:** Boot drops to initramfs shell - need rootfs or netboot config
2. **Kernel Format:** Alpine vmlinuz is EFI PE - must use `extractEmbeddedKernel` (gzip scan)
3. **State Management:** ✅ FIXED - Delegates now properly clear VM state on unexpected stop
4. **Console Output:** ✅ FIXED - ANSI escape codes are now stripped from console output

---

## Rootfs Setup

### Current State (Initramfs Only)
The VM currently boots with only an initramfs (no persistent rootfs). This is sufficient for testing boot but limits functionality.

**What happens:**
- Alpine initramfs loads successfully
- Boot drops to BusyBox shell (no full OS)
- No package manager or persistent storage
- Useful for diagnostics but not for running agents

### Option 1: Netboot (Lightweight)
Configure Alpine to download packages from the internet on boot:

```swift
// In createMinimalLinuxVMConfiguration()
bootLoader.commandLine = "console=hvc0 alpine_repo=http://dl-cdn.alpinelinux.org/alpine/v3.21/main modloop=http://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot/modloop-virt"
```

**Pros:** No disk image needed, always fresh packages  
**Cons:** Requires network access, slower boot

### Option 2: Disk Image with Rootfs (Full Featured)
Create a persistent disk with a full Alpine installation:

1. **Create disk image:**
   ```bash
   # On host
   dd if=/dev/zero of=alpine-root.img bs=1M count=1024  # 1GB
   mkfs.ext4 alpine-root.img
   ```

2. **Mount and install Alpine:**
   ```bash
   # This requires running on a Linux system or in a VM
   mkdir /tmp/alpine-mount
   sudo mount -o loop alpine-root.img /tmp/alpine-mount
   # Extract Alpine rootfs tarball into mount point
   # Configure /etc/fstab, install packages, etc.
   sudo umount /tmp/alpine-mount
   ```

3. **Attach in Swift:**
   ```swift
   // In createMinimalLinuxVMConfiguration()
   let diskURL = linuxDir.appendingPathComponent("alpine-root.img")
   let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
   let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
   config.storageDevices = [blockDevice]
   
   // Update kernel command line to use it
   bootLoader.commandLine = "console=hvc0 root=/dev/vda rw"
   ```

**Pros:** Full OS features, package manager, persistence  
**Cons:** Larger disk usage (~500MB-2GB), more setup complexity

### Option 3: Quick Start (Recommended for Development)
For testing, enable the netboot configuration:

1. Set `attachLinuxNetwork = true` in VMIsolationService
2. Update command line to include `alpine_repo=...`
3. VM will download needed packages on first boot

---

## Next Steps (When Prioritized)

### 1. Fix Boot
- [ ] Pass `alpine_repo` kernel arg for netboot
- [ ] OR attach disk image with rootfs (see Rootfs Setup section above)
- [ ] Enable network for package installation

### 2. Console Improvements
- [x] Strip ANSI escape codes from output ✅
- [ ] Add filtering/search in console view
- [ ] Consider throttle adjustments (currently 0.25s/4KB)

### 3. Quick-Start Presets
- [ ] Add preset configurations (minimal, development, build-server)
- [ ] Auto-configure network/disk based on preset
- [ ] Template command lines for common use cases

### 4. State Management
- [x] Clear VM state on unexpected stop ✅
- [ ] Add VM health monitoring
- [ ] Auto-restart on crash (optional)

---

## Use Case

VM isolation enables running untrusted agent code in a sandbox:
- Agent gets worktree copied into VM
- Agent runs in isolated environment
- Results extracted, VM destroyed
- Zero state bleed between runs

**Note:** This is a Phase 4 feature per the roadmap. Focus on CLI-based agents first.
