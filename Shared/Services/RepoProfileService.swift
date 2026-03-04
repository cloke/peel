//
//  RepoProfileService.swift
//  Peel
//
//  Discovers, caches, and serves .peel/profile.json data.
//  Provides prompt generation for injecting repo knowledge into agent context.
//  Used by DevServerManager (boot config), UXTestOrchestrator (app selection),
//  and ParallelWorktreeRunner (prompt injection).
//

import Foundation
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "RepoProfileService")

/// Service for loading and caching repo profiles, and generating agent prompt context.
@MainActor
@Observable
final class RepoProfileService {

  // MARK: - Properties

  /// Cached profiles, keyed by resolved repo path
  private var cache: [String: RepoProfile] = [:]

  /// Profile load timestamps for cache invalidation
  private var loadTimestamps: [String: Date] = [:]

  /// Cache TTL — profiles reload after this interval
  private let cacheTTL: TimeInterval = 300  // 5 minutes

  // MARK: - Loading

  /// Load a profile for a repo path. Uses cache if fresh, otherwise reloads from disk.
  func profile(for repoPath: String) -> RepoProfile? {
    let resolved = resolvedPath(repoPath)

    // Check cache freshness
    if let cached = cache[resolved],
       let loadedAt = loadTimestamps[resolved],
       Date().timeIntervalSince(loadedAt) < cacheTTL {
      return cached
    }

    // Load from disk
    let profile = RepoProfile.load(from: resolved)
    if let profile {
      cache[resolved] = profile
      loadTimestamps[resolved] = Date()
      logger.info("Loaded repo profile for \(profile.name) at \(resolved)")
    } else {
      // Also check parent directories (worktrees may be nested)
      if let parentProfile = findProfileInParents(of: resolved) {
        cache[resolved] = parentProfile
        loadTimestamps[resolved] = Date()
        logger.info("Found repo profile for \(parentProfile.name) via parent search from \(resolved)")
        return parentProfile
      }
      cache.removeValue(forKey: resolved)
      loadTimestamps.removeValue(forKey: resolved)
    }

    return profile
  }

  /// Force reload a profile from disk.
  func reload(for repoPath: String) -> RepoProfile? {
    let resolved = resolvedPath(repoPath)
    cache.removeValue(forKey: resolved)
    loadTimestamps.removeValue(forKey: resolved)
    return profile(for: resolved)
  }

  /// Clear all cached profiles.
  func clearCache() {
    cache.removeAll()
    loadTimestamps.removeAll()
  }

  // MARK: - App Resolution

  /// Resolve which app to run from a profile, given optional app name hint.
  /// Returns (appDef, resolvedPath) — the path is the absolute app directory.
  func resolveApp(repoPath: String, appName: String? = nil) -> (AppDefinition, String)? {
    guard let profile = profile(for: repoPath) else { return nil }
    guard let apps = profile.apps, !apps.isEmpty else { return nil }

    let app: AppDefinition?
    if let name = appName {
      app = profile.app(named: name)
    } else {
      app = profile.primaryApp
    }

    guard let resolved = app else { return nil }
    let appPath = (repoPath as NSString).appendingPathComponent(resolved.path)
    return (resolved, appPath)
  }

  // MARK: - Dev Server Config

  /// Get the dev server command for an app, with port substitution.
  func devServerCommand(repoPath: String, appName: String? = nil, port: UInt16) -> DevServerConfig? {
    guard let (app, appPath) = resolveApp(repoPath: repoPath, appName: appName) else { return nil }

    // If there's a port override command, use it
    if let overrideCmd = app.portOverrideCommand {
      let command = overrideCmd
        .replacingOccurrences(of: "{{PORT}}", with: "\(port)")
        .replacingOccurrences(of: "{{APP_PATH}}", with: appPath)
      return DevServerConfig(
        appPath: appPath,
        command: command,
        port: port,
        bootTimeSeconds: app.bootTimeSeconds ?? 30,
        entryPath: app.entryPath ?? "/",
        portConfigFile: app.portConfigFile,
        portConfigPattern: app.portConfigPattern
      )
    }

    // Otherwise use the dev command with basic port passing
    let devCmd = app.devCommand ?? "npm run dev"
    return DevServerConfig(
      appPath: appPath,
      command: devCmd,
      port: port,
      bootTimeSeconds: app.bootTimeSeconds ?? 30,
      entryPath: app.entryPath ?? "/",
      portConfigFile: app.portConfigFile,
      portConfigPattern: app.portConfigPattern
    )
  }

  /// Structured dev server configuration.
  struct DevServerConfig: Sendable {
    let appPath: String
    let command: String
    let port: UInt16
    let bootTimeSeconds: Int
    let entryPath: String
    let portConfigFile: String?
    let portConfigPattern: String?
  }

  // MARK: - Prompt Generation

  /// Build a comprehensive prompt context block from a repo profile.
  /// This is injected into agent prompts to make them immediately productive.
  func buildPromptContext(repoPath: String, appName: String? = nil) -> String? {
    guard let profile = profile(for: repoPath) else { return nil }

    var sections: [String] = []

    // Header
    sections.append("## Repository Profile: \(profile.name)")
    if let desc = profile.description {
      sections.append(desc)
    }

    // Repo type & package manager
    var meta: [String] = []
    if let type = profile.type { meta.append("**Type:** \(type.rawValue)") }
    if let pm = profile.packageManager { meta.append("**Package Manager:** \(pm.rawValue)") }
    if let install = profile.installCommand { meta.append("**Install:** `\(install)`") }
    if !meta.isEmpty { sections.append(meta.joined(separator: "\n")) }

    // Apps
    if let apps = profile.apps, !apps.isEmpty {
      var appSection = "### Apps\n"
      for app in apps {
        let primary = app.isPrimary == true ? " ⭐ (primary)" : ""
        appSection += "\n- **\(app.name)**\(primary): `\(app.path)/`"
        if let desc = app.description { appSection += "\n  \(desc)" }
        if let fw = app.framework { appSection += "\n  Framework: \(fw)" }
        if let cmd = app.devCommand { appSection += "\n  Dev command: `\(cmd)`" }
        if let port = app.defaultPort { appSection += "\n  Default port: \(port)" }
        if let entry = app.entryPath { appSection += "\n  Entry: \(entry)" }
        if let boot = app.bootTimeSeconds { appSection += "\n  Cold boot: ~\(boot)s" }
      }
      sections.append(appSection)
    }

    // Auth
    if let auth = profile.auth {
      var authSection = "### Authentication\n"
      if let method = auth.method { authSection += "\n- Method: \(method.rawValue)" }
      if auth.requiresAuth == true { authSection += "\n- Login required to access the app" }
      if let loginPath = auth.loginPath { authSection += "\n- Login page: \(loginPath)" }
      if let instructions = auth.loginInstructions {
        authSection += "\n\n#### Login Steps\n\(instructions)"
      }
      if let accounts = auth.testAccounts, !accounts.isEmpty {
        authSection += "\n\n#### Test Accounts (dev only)\n"
        for account in accounts {
          authSection += "- **\(account.role)**: `\(account.username)`"
          if let pw = account.password { authSection += " / `\(pw)`" }
          if let notes = account.notes { authSection += " — \(notes)" }
          authSection += "\n"
        }
      }
      if let publicPaths = auth.publicPaths, !publicPaths.isEmpty {
        authSection += "\nPublic paths (no auth): \(publicPaths.joined(separator: ", "))"
      }
      sections.append(authSection)
    }

    // Structure
    if let structure = profile.structure {
      var structSection = "### Project Structure\n"
      if let dirs = structure.directories {
        for dir in dirs {
          structSection += "\n- `\(dir.path)/` — \(dir.description)"
        }
      }
      if let files = structure.keyFiles {
        structSection += "\n\n**Key Files:**"
        for file in files {
          structSection += "\n- `\(file.path)` — \(file.description)"
        }
      }
      if let packages = structure.sharedPackages {
        structSection += "\n\n**Shared Packages:**"
        for pkg in packages {
          structSection += "\n- `\(pkg.path)` (\(pkg.name))"
          if let desc = pkg.description { structSection += " — \(desc)" }
        }
      }
      sections.append(structSection)
    }

    // Testing
    if let testing = profile.testing {
      var testSection = "### Testing\n"
      if let cmd = testing.testCommand { testSection += "\n- Run all: `\(cmd)`" }
      if let single = testing.singleTestCommand { testSection += "\n- Single file: `\(single)`" }
      if let fw = testing.framework { testSection += "\n- Framework: \(fw)" }
      if let dir = testing.testDirectory { testSection += "\n- Test dir: `\(dir)`" }
      if let lint = testing.lintCommand { testSection += "\n- Lint: `\(lint)`" }
      if let tc = testing.typeCheckCommand { testSection += "\n- Type check: `\(tc)`" }
      sections.append(testSection)
    }

    // Conventions
    if let conv = profile.conventions {
      var convSection = "### Coding Conventions\n"
      if let versions = conv.languageVersions {
        convSection += "\n**Language Versions:**"
        for (lang, ver) in versions.sorted(by: { $0.key < $1.key }) {
          convSection += "\n- \(lang): \(ver)"
        }
      }
      if let style = conv.styleGuide { convSection += "\n\n\(style)" }
      if let patterns = conv.patterns, !patterns.isEmpty {
        convSection += "\n\n**Patterns to follow:**"
        for p in patterns { convSection += "\n- \(p)" }
      }
      if let anti = conv.antiPatterns, !anti.isEmpty {
        convSection += "\n\n**Anti-patterns to avoid:**"
        for a in anti { convSection += "\n- ❌ \(a)" }
      }
      if let naming = conv.naming { convSection += "\n\n**Naming:** \(naming)" }
      sections.append(convSection)
    }

    // Environment
    if let env = profile.environment {
      if let services = env.services, !services.isEmpty {
        sections.append("### External Services\n\nRequires: \(services.joined(separator: ", "))")
      }
    }

    // Custom agent instructions
    if let instructions = profile.agentInstructions {
      sections.append("### Agent Instructions\n\n\(instructions)")
    }

    return sections.joined(separator: "\n\n")
  }

  // MARK: - Private

  private func resolvedPath(_ path: String) -> String {
    (path as NSString).standardizingPath
  }

  /// Walk up parent directories looking for a .peel/profile.json.
  /// This handles worktrees that are nested inside a repo.
  private func findProfileInParents(of path: String) -> RepoProfile? {
    var current = (path as NSString).deletingLastPathComponent
    let root = "/"
    var depth = 0
    let maxDepth = 5

    while current != root && depth < maxDepth {
      if let profile = RepoProfile.load(from: current) {
        return profile
      }
      current = (current as NSString).deletingLastPathComponent
      depth += 1
    }
    return nil
  }
}
