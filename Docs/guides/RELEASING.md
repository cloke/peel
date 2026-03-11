# Releasing Peel

## Quick Start

```bash
# Dry run (build + zip, no push)
Tools/release.sh v1.2.0 --dry-run

# Create a release
Tools/release.sh v1.2.0

# Draft release (visible only to repo collaborators)
Tools/release.sh v1.2.0 --draft

# With notarization (requires Developer ID cert)
Tools/release.sh v1.2.0 --notarize

# Custom release notes
Tools/release.sh v1.2.0 --notes-file tmp/my-notes.md
```

## What the Script Does

1. **Validates** version format (`vX.Y.Z`), clean working tree, current branch
2. **Updates** `CFBundleShortVersionString` in both Info.plists to match
3. **Tags** the current commit with the version
4. **Builds** Release configuration via `Tools/build-config.sh`
5. **Verifies** code signature
6. **Notarizes** (optional, if `--notarize` and Developer ID cert available)
7. **Zips** with `ditto` (preserves macOS metadata, code signatures, symlinks)
8. **Computes** SHA-256 checksum of the zip
9. **Pushes** the tag to origin
10. **Creates** GitHub Release with the zip as an asset and auto-generated release notes

## Version Scheme

| Field | Example | Purpose |
|-------|---------|---------|
| `CFBundleShortVersionString` | `1.2.0` | Marketing version shown to users |
| `CFBundleVersion` | `13` | Build number (increment in Xcode) |
| `PeelGitCommitHash` | `abc1234` | Git SHA stamped at build time |
| Git tag | `v1.2.0` | Immutable release pointer |

The About panel shows: `1.2.0 (13) · abc1234`

## Prerequisites

### Required
- **gh CLI** authenticated: `gh auth status`
- **Xcode** with the Peel scheme configured
- **Clean working tree**: commit or stash changes first

### For Notarization (optional)
1. **Developer ID Application certificate** in your Keychain
   - Get from [Apple Developer Certificates](https://developer.apple.com/account/resources/certificates/list)
   - Choose "Developer ID Application"
   
2. **Update Release signing identity** in Xcode:
   - Peel (macOS) target → Build Settings → Release
   - Set `CODE_SIGN_IDENTITY` = `Developer ID Application`
   
3. **Store notarization credentials**:
   ```bash
   xcrun notarytool store-credentials "Peel-Notarize" \
     --apple-id YOUR_APPLE_ID@example.com \
     --team-id UNX9FJDDXV \
     --password YOUR_APP_SPECIFIC_PASSWORD
   ```
   Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com)

## Distribution Without Notarization

For personal/swarm distribution (trusted machines), notarization isn't needed.
Users allow the app on first launch:
- Right-click the app → Open → Open (bypasses Gatekeeper)
- Or: System Settings → Privacy & Security → Allow

## Auto-Update

Peel checks for updates via the GitHub Releases API. Users see:
- **Peel menu → Check for Updates…** (manual check)
- **Automatic check** on launch (if last check was >24h ago)

The update checker compares the local `CFBundleShortVersionString` against the
latest release `tag_name`. When an update is available, it offers to open the
release page or download directly.

## Artifacts

Release artifacts are stored in `tmp/` (gitignored):
- `tmp/Peel-vX.Y.Z-macos.zip` — The distributable zip
- `tmp/release-notes.md` — Auto-generated release notes (temporary)

## Troubleshooting

### "Uncommitted changes detected"
Commit or stash before releasing. The script enforces a clean tree so the tag
points to exactly what's distributed.

### "Tag already exists"  
Either delete the old tag (`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`)
or use a new version number.

### Notarization fails
- Check `tmp/notarize-log.txt` for details
- Ensure hardened runtime is enabled (it is by default)
- Verify the app doesn't use private APIs or restricted entitlements
- Run `xcrun notarytool log <submission-id>` for the full Apple log

### Build fails
Check the build output. Common issues:
- Package resolution failures → `rm -rf build/SourcePackages && Tools/build.sh Release`
- Signing issues → verify your certificate in Keychain Access
