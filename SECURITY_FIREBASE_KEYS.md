# Firebase Security - Credential Management

## 🚨 Critical: API Key Compromised

The `GoogleService-Info.plist` file was inadvertently committed to public source control. The API key has been exposed:
- **Exposed Key**: `AIzaSyAkVtMIgGEYyh7OMFEOtUUbjYcq3TU9xTM` ❌ **INVALIDATED**
- **Project**: `peel-swarm` 
- **Exposed Since**: Git history (commit ee7525f and earlier)

## ✅ Remediation Steps Completed

1. **Added `GoogleService-Info.plist` to `.gitignore`** — prevents future commits
2. **Added environment variable documentation** — see below for setup

## 🔐 Setup Instructions (for you & contributors)

### Step 1: Regenerate API Key (Google Cloud Console)

1. Go to https://console.cloud.google.com/
2. Select project: `peel-swarm`
3. Go to **Credentials** (left sidebar)
4. Find the old key `AIzaSyAkVtMIgGEYyh7OMFEOtUUbjYcq3TU9xTM`
5. Click it, then click **Regenerate Key**
6. Copy the new key

### Step 2: Add API Key Restrictions

After regenerating the key:

1. Click the regenerated key in Credentials
2. Under **Application restrictions**:
   - Select **iOS apps**
   - Add Bundle ID: `crunchy-bananas.Peel`
3. Under **API restrictions**:
   - Select **Restrict key** → **Cloud Firestore API** (and any others needed)
4. Save

### Step 3: Create Local GoogleService-Info.plist

For **local development only**, create `GoogleService-Info.plist` with your new key:

```bash
cat > GoogleService-Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>API_KEY</key>
	<string>YOUR_NEW_API_KEY_HERE</string>
	<key>GCM_SENDER_ID</key>
	<string>552381851334</string>
	<key>PLIST_VERSION</key>
	<string>1</string>
	<key>BUNDLE_ID</key>
	<string>crunchy-bananas.Peel</string>
	<key>PROJECT_ID</key>
	<string>peel-swarm</string>
	<key>STORAGE_BUCKET</key>
	<string>peel-swarm.firebasestorage.app</string>
	<key>IS_ADS_ENABLED</key>
	<false></false>
	<key>IS_ANALYTICS_ENABLED</key>
	<false></false>
	<key>IS_APPINVITE_ENABLED</key>
	<true></true>
	<key>IS_GCM_ENABLED</key>
	<true></true>
	<key>IS_SIGNIN_ENABLED</key>
	<true></true>
	<key>GOOGLE_APP_ID</key>
	<string>1:552381851334:ios:0e381bcd6f4be398bc99c7</string>
</dict>
</plist>
EOF
```

Replace `YOUR_NEW_API_KEY_HERE` with your regenerated key.

### Step 4: Remove from Git History (Optional but Recommended)

To remove the file from all git history (prevents anyone from finding it in old commits):

```bash
# Install git-filter-repo if not present
brew install git-filter-repo

# Remove GoogleService-Info.plist from all history
git filter-repo --path GoogleService-Info.plist --invert-paths

# Force push (only if you're the sole contributor, or coordinate with team)
git push origin --force --all
```

⚠️ **Warning**: `--force` rewrites history. Only do this if:
- You're the repository owner
- No other developers have unpulled commits
- You coordinate with the team first

## 📋 Checklist for Contributors

If you're cloning this repo for the first time:

- [ ] Ask the maintainer for a `GoogleService-Info.plist` with a valid API key
- [ ] Place it in the repository root (it's in `.gitignore` and won't be committed)
- [ ] **Never commit it** — git will warn you if you try (`git status`)
- [ ] Use restricted API keys with:
  - Bundle ID restrictions (iOS apps only)
  - API restrictions (Firestore, Auth, etc.)

## 🛡️ Best Practices Going Forward

1. **Never commit credentials** — use `.gitignore`
2. **Use restricted keys** — always enable bundle ID and API restrictions
3. **Rotate keys regularly** — even if not compromised, rotate yearly
4. **Use environment variables for CI/CD** — store keys in GitHub Secrets, not the repo
5. **Monitor activity** — check Google Cloud Console usage monthly for anomalies

## 📞 Support

If you suspect the key was misused:
1. Check Google Cloud Console → Logs for unexpected API calls
2. Review Firebase usage → Firestore read/write spikes
3. Enable Cloud Audit Logs for detailed forensics

---

**Last Updated**: March 2, 2026  
**Status**: Awaiting API key regeneration and history cleanup
