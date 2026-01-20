---
title: VM Bootstrap for GitHub Auth
status: active
updated: 2026-01-20
audience:
  - developer
  - ai-agent
related_issues:
  - 54
---

# VM Bootstrap for GitHub Auth + Repo Provisioning

## Summary
A repeatable VM bootstrap flow that avoids copying personal SSH keys into VMs and supports parallel agent sessions.

## Recommended Auth Options
1. **GitHub App installation token (preferred)**
   - Short-lived token scoped to repositories.
2. **Deploy keys (per-repo)**
   - Useful if App tokens are not available.
3. **`gh auth login --device` fallback**
   - Manual step when other options fail.

## Suggested Bootstrap Steps
1. Install GitHub CLI
2. Inject a short-lived token (App or deploy key)
3. Clone repo with HTTPS
4. Configure git author (bot identity)
5. Run agent workflow

## Example (App Token)
```bash
export GITHUB_TOKEN="$APP_TOKEN"
gh auth login --with-token <<< "$GITHUB_TOKEN"

REPO_URL="https://github.com/cloke/peel.git"
mkdir -p ~/repos && cd ~/repos
git clone "$REPO_URL"
```

## Example (Deploy Key)
```bash
mkdir -p ~/.ssh
cat <<'EOF' > ~/.ssh/id_ed25519
<DEPLOY_KEY_PRIVATE>
EOF
chmod 600 ~/.ssh/id_ed25519
ssh-keyscan github.com >> ~/.ssh/known_hosts

git clone git@github.com:cloke/peel.git
```

## Acceptance Criteria
- VM can authenticate without manual SSH key copy.
- Repo can be cloned and agent runs can execute.
- Documented fallback path for GH device login.
