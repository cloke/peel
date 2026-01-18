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
3. **UI Copy:** Says "Fedora" but downloads Alpine/Debian - update labels
4. **State Bug:** If VM stops unexpectedly, `runningLinuxVM` isn't cleared

---

## Next Steps (When Prioritized)

### 1. Fix Boot
- [ ] Pass `alpine_repo` kernel arg for netboot
- [ ] OR attach disk image with rootfs
- [ ] Enable network for package installation

### 2. Console Cleanup
- [ ] Strip ANSI escape codes from output
- [ ] Throttle updates (currently 0.25s/4KB)

### 3. Decide Distro
| Option | Pros | Cons |
|--------|------|------|
| Debian | glibc, broad compatibility | Larger |
| Alpine | Tiny, fast boot | musl, some tools need compat |

---

## Use Case

VM isolation enables running untrusted agent code in a sandbox:
- Agent gets worktree copied into VM
- Agent runs in isolated environment
- Results extracted, VM destroyed
- Zero state bleed between runs

**Note:** This is a Phase 4 feature per the roadmap. Focus on CLI-based agents first.
