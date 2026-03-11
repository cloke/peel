#!/bin/zsh
#
# release.sh — Build, zip, and publish a Peel release to GitHub
#
# Usage:
#   Tools/release.sh v1.2.0                  # Tag, build, zip, create release
#   Tools/release.sh v1.2.0 --draft          # Create as draft release
#   Tools/release.sh v1.2.0 --dry-run        # Build + zip only, don't push
#   Tools/release.sh v1.2.0 --notarize       # Also notarize before uploading
#   Tools/release.sh v1.2.0 --notes-file tmp/notes.md  # Custom release notes
#
# Prerequisites:
#   - gh CLI authenticated with repo + release scope
#   - Clean working tree (no uncommitted changes)
#   - On the main branch
#   - For --notarize: Developer ID Application cert + App Store Connect API key

set -e
source "$(dirname "$0")/build-config.sh"

VERSION="${1:?Usage: Tools/release.sh <version> [--draft] [--dry-run] [--notarize] [--notes-file <path>]}"
DRAFT=false
DRY_RUN=false
NOTARIZE=false
NOTES_FILE=""

shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --draft) DRAFT=true ;;
    --dry-run) DRY_RUN=true ;;
    --notarize) NOTARIZE=true ;;
    --notes-file) shift; NOTES_FILE="$1" ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# Validate version format
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Version must match vX.Y.Z (e.g., v1.2.0)"
  exit 1
fi

MARKETING_VERSION="${VERSION#v}"
cd "$PROJECT_DIR"

# Check for clean working tree
if ! git diff --quiet HEAD 2>/dev/null; then
  echo "❌ Uncommitted changes detected. Commit or stash before releasing."
  exit 1
fi

# Check we're on main
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
  echo "⚠️  Warning: releasing from branch '$BRANCH' (not main)"
  read -q "REPLY?Continue? [y/N] " || exit 1
  echo
fi

COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_HASH_FULL=$(git rev-parse HEAD)

echo "🍊 Peel Release: ${VERSION}"
echo "========================="
echo "📌 Commit: ${COMMIT_HASH}"
echo "📦 Marketing version: ${MARKETING_VERSION}"
echo ""

# 1. Update version in Xcode project
echo "📝 Updating version in project..."
PBXPROJ="${PROJECT_DIR}/Peel.xcodeproj/project.pbxproj"
# Update MARKETING_VERSION if it exists, otherwise update CFBundleShortVersionString in plists
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = ${MARKETING_VERSION};/g" "$PBXPROJ" 2>/dev/null || true

# Update CFBundleShortVersionString in Info.plists
for plist in macOS/Info.plist iOS/Info.plist; do
  if [[ -f "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "$plist" 2>/dev/null || true
  fi
done

# 2. Create git tag
if git tag -l "$VERSION" | grep -q "$VERSION"; then
  echo "⚠️  Tag ${VERSION} already exists"
else
  if [[ "$DRY_RUN" == "false" ]]; then
    echo "📌 Creating tag ${VERSION}..."
    git tag -a "$VERSION" -m "Release ${VERSION}"
  else
    echo "📌 [dry-run] Would create tag ${VERSION}"
  fi
fi

# 3. Build Release configuration
echo ""
echo "🔨 Building Release..."
peel_acquire_build_lock --wait
trap peel_release_build_lock EXIT

RELEASE_APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}"

if ! peel_build Release; then
  echo "❌ Build failed"
  exit 1
fi

echo "✅ Build succeeded: ${RELEASE_APP_PATH}"

# Verify code signing
echo ""
echo "🔏 Verifying code signature..."
SIGN_IDENTITY=$(codesign -dvvv "${RELEASE_APP_PATH}" 2>&1 | grep "Authority=" | head -1 | sed 's/Authority=//')
echo "   Signed by: ${SIGN_IDENTITY}"
if codesign --verify --strict "${RELEASE_APP_PATH}" 2>/dev/null; then
  echo "   ✅ Signature valid"
else
  echo "   ⚠️  Signature verification failed (may work for personal distribution)"
fi

# 4. Notarize (optional)
if [[ "$NOTARIZE" == "true" ]]; then
  echo ""
  echo "📋 Notarizing..."

  # Check for Developer ID signing
  if [[ "$SIGN_IDENTITY" != *"Developer ID"* ]]; then
    echo "⚠️  App is signed with '${SIGN_IDENTITY}', not Developer ID Application."
    echo "   Notarization requires Developer ID. Set CODE_SIGN_IDENTITY in Release config."
    echo "   Continuing without notarization..."
    NOTARIZE=false
  else
    # Create a zip for notarization
    NOTARIZE_ZIP="${PROJECT_DIR}/tmp/Peel-notarize.zip"
    ditto -c -k --keepParent "${RELEASE_APP_PATH}" "${NOTARIZE_ZIP}"

    # Submit for notarization
    echo "   Submitting to Apple notary service..."
    if xcrun notarytool submit "${NOTARIZE_ZIP}" \
        --keychain-profile "Peel-Notarize" \
        --wait 2>&1 | tee "${PROJECT_DIR}/tmp/notarize-log.txt"; then
      echo "   ✅ Notarization succeeded"

      # Staple the ticket
      echo "   Stapling notarization ticket..."
      xcrun stapler staple "${RELEASE_APP_PATH}"
      echo "   ✅ Ticket stapled"
    else
      echo "   ❌ Notarization failed. Check tmp/notarize-log.txt"
      echo ""
      echo "   To set up notarization credentials:"
      echo "   xcrun notarytool store-credentials \"Peel-Notarize\" \\"
      echo "     --apple-id YOUR_APPLE_ID \\"
      echo "     --team-id UNX9FJDDXV \\"
      echo "     --password APP_SPECIFIC_PASSWORD"
      exit 1
    fi

    rm -f "${NOTARIZE_ZIP}"
  fi
fi

# 5. Zip with ditto (preserves macOS metadata, code signatures, symlinks)
ZIP_NAME="Peel-${VERSION}-macos.zip"
ZIP_PATH="${PROJECT_DIR}/tmp/${ZIP_NAME}"
mkdir -p "${PROJECT_DIR}/tmp"

echo ""
echo "📦 Creating ${ZIP_NAME}..."
ditto -c -k --keepParent "${RELEASE_APP_PATH}" "${ZIP_PATH}"
ZIP_SIZE=$(stat -f%z "${ZIP_PATH}")
echo "   Size: $(( ZIP_SIZE / 1048576 )) MB"

# Compute SHA-256 for verification
ZIP_SHA256=$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')
echo "   SHA-256: ${ZIP_SHA256}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "✅ [dry-run] Built and zipped: ${ZIP_PATH}"
  echo "   Would push tag ${VERSION} and create GitHub Release"
  echo ""
  echo "   Artifact: ${ZIP_PATH}"
  echo "   SHA-256:  ${ZIP_SHA256}"
  exit 0
fi

# 6. Push tag
echo ""
echo "📤 Pushing tag ${VERSION}..."
git push origin "$VERSION"

# 7. Create GitHub Release
echo ""
echo "📝 Creating GitHub Release..."

# Build release notes
if [[ -n "$NOTES_FILE" ]] && [[ -f "$NOTES_FILE" ]]; then
  NOTES_CONTENT=$(cat "$NOTES_FILE")
else
  # Auto-generate release notes
  PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")
  if [[ -n "$PREV_TAG" ]]; then
    CHANGELOG=$(git log --oneline "${PREV_TAG}..HEAD" --no-merges | head -20)
    COMPARE_URL="https://github.com/cloke/peel/compare/${PREV_TAG}...${VERSION}"
  else
    CHANGELOG=$(git log --oneline -10 --no-merges)
    COMPARE_URL=""
  fi

  NOTES_CONTENT="## Peel ${VERSION}

**Commit:** ${COMMIT_HASH_FULL}
**SHA-256:** \`${ZIP_SHA256}\`

### Changes
\`\`\`
${CHANGELOG}
\`\`\`"

  if [[ -n "$COMPARE_URL" ]]; then
    NOTES_CONTENT="${NOTES_CONTENT}

[Full changelog](${COMPARE_URL})"
  fi
fi

# Write notes to temp file to avoid shell escaping issues
NOTES_TMP="${PROJECT_DIR}/tmp/release-notes.md"
echo "$NOTES_CONTENT" > "$NOTES_TMP"

RELEASE_FLAGS=(
  --repo "cloke/peel"
  --title "Peel ${VERSION}"
  --notes-file "$NOTES_TMP"
)

if [[ "$DRAFT" == "true" ]]; then
  RELEASE_FLAGS+=(--draft)
fi

gh release create "$VERSION" "${RELEASE_FLAGS[@]}" "${ZIP_PATH}"

rm -f "$NOTES_TMP"

echo ""
echo "✅ Release ${VERSION} published!"
echo "   https://github.com/cloke/peel/releases/tag/${VERSION}"
echo ""
echo "   Artifact: ${ZIP_NAME} ($(( ZIP_SIZE / 1048576 )) MB)"
echo "   SHA-256:  ${ZIP_SHA256}"
