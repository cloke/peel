---
title: iOS Feature Matrix
status: active
updated: 2026-01-20
audience:
  - developer
  - ai-agent
---

# iOS Feature Matrix

This matrix documents which Peel features are available on iOS versus macOS and the reasons for any limitations.

## Legend
- ✅ Supported
- ⚠️ Limited
- ❌ Not applicable / not supported

| Area | macOS | iOS | Notes |
|------|------:|----:|-------|
| Git repositories (local) | ✅ | ⚠️ | iOS sandbox limits CLI tools and file system access. Basic browsing works when data is available. |
| GitHub browsing | ✅ | ✅ | API-driven views are shared and supported. |
| Pull requests | ✅ | ✅ | View and browse PRs on both platforms. |
| PR review with agent | ✅ | ⚠️ | Agent workflows depend on CLI/worktrees; iOS cannot spawn local worktrees. |
| Homebrew | ✅ | ❌ | Homebrew is macOS-only. |
| Agents UI | ✅ | ⚠️ | Limited on iOS; no CLI tools, fewer automation hooks. |
| MCP server | ✅ | ❌ | MCP server is macOS-only (local tooling + permissions). |
| MCP UI automation | ✅ | ❌ | Requires macOS accessibility + UI automation APIs. |
| Local RAG | ✅ | ⚠️ | Indexing and embeddings are macOS-first; iOS can query in-memory if data exists. |
| PII Scrubber | ✅ | ❌ | Depends on local CLI tools and file system access. |
| Translation validator | ✅ | ❌ | Depends on CLI tools and file system access. |
| Settings/Preferences | ✅ | ✅ | iOS settings are limited to shared preferences. |

## Notes
- iOS does not allow process execution of local CLI tools, so agent orchestration features that require worktrees or shell access are limited.
- GitHub API features are shared between platforms.
- Local ML features that require on-device models may become available on iOS as the model pipeline stabilizes.
