//
//  RepoProfile.swift
//  Peel
//
//  Defines the `.peel/profile.json` schema — structured metadata about a repository
//  that makes agents immediately productive. Covers: apps, auth, structure,
//  dev setup, testing, coding conventions, and environment configuration.
//
//  Discovered automatically when a repo is indexed or a worktree is created.
//  Injected into agent prompts and used by DevServerManager for boot config.
//

import Foundation

// MARK: - Root Profile

/// A repository profile that tells agents everything they need to know.
/// Lives at `.peel/profile.json` in the repo root.
struct RepoProfile: Codable, Sendable {
  /// Schema version for forwards compatibility
  var version: Int = 1

  /// Human-readable repo name
  var name: String

  /// Brief description of what this repo contains
  var description: String?

  /// Repo type hint
  var type: RepoType?

  /// Package manager / runtime
  var packageManager: PackageManager?

  /// Install command (e.g., "pnpm install --frozen-lockfile")
  var installCommand: String?

  /// Apps/services within this repo (supports monorepos)
  var apps: [AppDefinition]?

  /// Authentication/login instructions for agents
  var auth: AuthConfig?

  /// Repo structure hints for navigation
  var structure: StructureConfig?

  /// Environment variable configuration
  var environment: EnvironmentConfig?

  /// Testing configuration
  var testing: TestingConfig?

  /// Coding conventions and patterns
  var conventions: ConventionsConfig?

  /// Custom agent instructions (free-form markdown injected into prompts)
  var agentInstructions: String?
}

// MARK: - Enums

enum RepoType: String, Codable, Sendable {
  case monorepo
  case singleApp = "single-app"
  case library
  case api
  case fullStack = "full-stack"
}

enum PackageManager: String, Codable, Sendable {
  case pnpm, npm, yarn, bun
  case cargo, swift, pip, poetry, bundler
}

// MARK: - App Definition

/// An app or service within the repo (critical for monorepos).
struct AppDefinition: Codable, Sendable, Identifiable {
  var id: String { name }

  /// App name (e.g., "tio-admin", "tio-employee")
  var name: String

  /// Brief description
  var description: String?

  /// Path relative to repo root (e.g., "tio-admin")
  var path: String

  /// Framework (e.g., "ember", "next", "rails", "vite", "express")
  var framework: String?

  /// The command to start the dev server (e.g., "pnpm start")
  var devCommand: String?

  /// Default port (will be overridden by Peel's port allocator in parallel mode)
  var defaultPort: Int?

  /// How to override the port — agents use this to start on a custom port.
  /// Supports placeholders: {{PORT}}, {{APP_PATH}}
  /// Examples:
  ///   - "sed -i '' 's/port: 4250/port: {{PORT}}/' vite.config.mjs && pnpm start"
  ///   - "PORT={{PORT}} pnpm start"
  ///   - "pnpm start -- --port {{PORT}}"
  var portOverrideCommand: String?

  /// Config file containing the port (for auto-sed in worktrees)
  var portConfigFile: String?

  /// Port config pattern to find/replace (regex)
  /// e.g., "port:\\s*\\d+" gets replaced with "port: {{PORT}}"
  var portConfigPattern: String?

  /// Entry URL path after boot (e.g., "/", "/admin", "/dashboard")
  var entryPath: String?

  /// Estimated cold-boot time in seconds (agents wait this long)
  var bootTimeSeconds: Int?

  /// Build command for this app (e.g., "cd tio-admin && pnpm build").
  /// Used by gate steps to verify the build passes after agent changes.
  /// Supports placeholders: {{APP_PATH}}
  var buildCommand: String?

  /// Whether this is the primary/default app
  var isPrimary: Bool?

  /// Environment variables needed for this app
  var envVars: [String: String]?
}

// MARK: - Auth Config

/// How to authenticate in the app.
struct AuthConfig: Codable, Sendable {
  /// Auth method
  var method: AuthMethod?

  /// Login page URL path (e.g., "/login")
  var loginPath: String?

  /// Step-by-step login instructions for agents (markdown)
  var loginInstructions: String?

  /// Test account credentials (for dev/staging only!)
  /// These should ONLY be used in dev environments.
  var testAccounts: [TestAccount]?

  /// Whether login is required to see the app
  var requiresAuth: Bool?

  /// Pages accessible without auth (e.g., ["/login", "/signup", "/forgot-password"])
  var publicPaths: [String]?
}

enum AuthMethod: String, Codable, Sendable {
  case formLogin = "form-login"
  case oauth
  case sso
  case apiKey = "api-key"
  case none
}

struct TestAccount: Codable, Sendable {
  /// Role/persona (e.g., "admin", "employer", "employee")
  var role: String

  /// Username or email
  var username: String

  /// Password (only for local dev environments — NEVER production)
  var password: String?

  /// Additional notes
  var notes: String?
}

// MARK: - Structure Config

/// Helps agents navigate the repo quickly.
struct StructureConfig: Codable, Sendable {
  /// Key directories and what they contain
  var directories: [DirectoryHint]?

  /// Important files to know about
  var keyFiles: [FileHint]?

  /// Shared packages/addons in a monorepo
  var sharedPackages: [SharedPackage]?
}

struct DirectoryHint: Codable, Sendable {
  var path: String
  var description: String
}

struct FileHint: Codable, Sendable {
  var path: String
  var description: String
}

struct SharedPackage: Codable, Sendable {
  var name: String
  var path: String
  var description: String?
}

// MARK: - Environment Config

/// Environment setup for the repo.
struct EnvironmentConfig: Codable, Sendable {
  /// Required env vars with descriptions
  var required: [EnvVarSpec]?

  /// Optional env vars
  var optional: [EnvVarSpec]?

  /// .env file location (e.g., ".env.local")
  var envFile: String?

  /// Example/template env file
  var envExampleFile: String?

  /// External services needed (e.g., ["postgres", "redis", "elasticsearch"])
  var services: [String]?
}

struct EnvVarSpec: Codable, Sendable {
  var name: String
  var description: String?
  var defaultValue: String?
  var required: Bool?
}

// MARK: - Testing Config

/// How to run tests.
struct TestingConfig: Codable, Sendable {
  /// Command to run all tests
  var testCommand: String?

  /// Command to run a single test file (use {{FILE}} placeholder)
  var singleTestCommand: String?

  /// Test framework (e.g., "qunit", "jest", "rspec", "xctest")
  var framework: String?

  /// Where tests live
  var testDirectory: String?

  /// Lint command
  var lintCommand: String?

  /// Type check command
  var typeCheckCommand: String?

  /// Build command (root-level fallback when no per-app buildCommand is set)
  var buildCommand: String?
}

// MARK: - Conventions Config

/// Coding conventions agents should follow.
struct ConventionsConfig: Codable, Sendable {
  /// Language/framework version constraints
  var languageVersions: [String: String]?

  /// Style guide reference or key rules (markdown)
  var styleGuide: String?

  /// Patterns to follow
  var patterns: [String]?

  /// Anti-patterns to avoid
  var antiPatterns: [String]?

  /// Import ordering rules
  var importOrder: String?

  /// Naming conventions
  var naming: String?
}

// MARK: - Loading

extension RepoProfile {
  /// The standard profile file path relative to repo root
  static let profilePath = ".peel/profile.json"

  /// Load a profile from a repo path. Returns nil if no profile exists.
  static func load(from repoPath: String) -> RepoProfile? {
    let filePath = (repoPath as NSString).appendingPathComponent(Self.profilePath)
    guard FileManager.default.fileExists(atPath: filePath) else { return nil }

    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      return try decoder.decode(RepoProfile.self, from: data)
    } catch {
      print("[RepoProfile] Failed to load \(filePath): \(error)")
      return nil
    }
  }

  /// Save a profile to a repo path.
  func save(to repoPath: String) throws {
    let dirPath = (repoPath as NSString).appendingPathComponent(".peel")
    let filePath = (dirPath as NSString).appendingPathComponent("profile.json")

    // Create .peel directory if needed
    try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    try data.write(to: URL(fileURLWithPath: filePath))
  }

  /// Find the primary app, or the first app if none is marked primary.
  var primaryApp: AppDefinition? {
    apps?.first(where: { $0.isPrimary == true }) ?? apps?.first
  }

  /// Find an app by name (case-insensitive).
  func app(named name: String) -> AppDefinition? {
    apps?.first(where: { $0.name.lowercased() == name.lowercased() })
  }
}
