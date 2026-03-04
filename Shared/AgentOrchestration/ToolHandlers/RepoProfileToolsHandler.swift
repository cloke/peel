//
//  RepoProfileToolsHandler.swift
//  Peel
//
//  MCP tool handler for repo profile management.
//  Provides tools: repo.profile.get, repo.profile.set, repo.profile.generate
//

import Foundation
import MCPCore
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "RepoProfileToolsHandler")

/// Handles MCP tools for `.peel/profile.json` repo profile management.
@MainActor
public final class RepoProfileToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  /// The profile service for loading/caching profiles
  var profileService: RepoProfileService?

  public let supportedTools: Set<String> = [
    "repo.profile.get",
    "repo.profile.set",
    "repo.profile.generate"
  ]

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let profileService else {
      return serviceNotActiveError(id: id, service: "RepoProfileService",
        hint: "Profile service is not initialized.")
    }

    switch name {
    case "repo.profile.get":
      return handleGet(id: id, arguments: arguments, service: profileService)
    case "repo.profile.set":
      return handleSet(id: id, arguments: arguments, service: profileService)
    case "repo.profile.generate":
      return await handleGenerate(id: id, arguments: arguments, service: profileService)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown profile tool: \(name)"))
    }
  }

  // MARK: - Tool Definitions

  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "repo.profile.get",
        description: "Get the .peel/profile.json for a repository. Returns structured metadata about apps, auth, structure, testing, and conventions that makes agents immediately productive.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Absolute path to the repository root"
            ],
            "appName": [
              "type": "string",
              "description": "Optional: get only this app's definition from the profile"
            ],
            "section": [
              "type": "string",
              "enum": ["apps", "auth", "structure", "environment", "testing", "conventions", "all"],
              "description": "Optional: return only a specific section (default: all)"
            ]
          ],
          "required": ["repoPath"]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "repo.profile.set",
        description: "Create or update a .peel/profile.json file. Accepts the full profile JSON or a partial update to merge.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Absolute path to the repository root"
            ],
            "profile": [
              "type": "object",
              "description": "Full profile JSON to write. Must follow the RepoProfile schema."
            ],
            "merge": [
              "type": "boolean",
              "description": "If true, merge with existing profile instead of replacing. Default: false"
            ]
          ],
          "required": ["repoPath", "profile"]
        ],
        category: .state,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "repo.profile.generate",
        description: "Auto-detect and generate a starter .peel/profile.json by analyzing the repository structure. Detects: package manager, apps, frameworks, test setup, and more. Returns the generated profile without writing it — use repo.profile.set to save.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Absolute path to the repository root"
            ],
            "save": [
              "type": "boolean",
              "description": "If true, also save the generated profile to .peel/profile.json. Default: false"
            ]
          ],
          "required": ["repoPath"]
        ],
        category: .state,
        isMutating: false
      )
    ]
  }

  // MARK: - Get

  private func handleGet(id: Any?, arguments: [String: Any], service: RepoProfileService) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "repoPath is required"))
    }

    guard let profile = service.profile(for: repoPath) else {
      return (200, makeResult(id: id, result: [
        "found": false,
        "message": "No .peel/profile.json found at \(repoPath). Use repo.profile.generate to create one."
      ]))
    }

    let section = optionalString("section", from: arguments) ?? "all"
    let appName = optionalString("appName", from: arguments)

    // If app name specified, return just that app's config
    if let appName {
      guard let app = profile.app(named: appName) else {
        return (200, makeResult(id: id, result: [
          "found": true,
          "error": "App '\(appName)' not found in profile. Available: \(profile.apps?.map { $0.name }.joined(separator: ", ") ?? "none")"
        ]))
      }
      return (200, makeResult(id: id, result: [
        "found": true,
        "app": encodeToDict(app)
      ]))
    }

    // Encode the full profile or a section
    switch section {
    case "apps":
      return (200, makeResult(id: id, result: ["found": true, "apps": encodeToDict(profile.apps)]))
    case "auth":
      return (200, makeResult(id: id, result: ["found": true, "auth": encodeToDict(profile.auth)]))
    case "structure":
      return (200, makeResult(id: id, result: ["found": true, "structure": encodeToDict(profile.structure)]))
    case "environment":
      return (200, makeResult(id: id, result: ["found": true, "environment": encodeToDict(profile.environment)]))
    case "testing":
      return (200, makeResult(id: id, result: ["found": true, "testing": encodeToDict(profile.testing)]))
    case "conventions":
      return (200, makeResult(id: id, result: ["found": true, "conventions": encodeToDict(profile.conventions)]))
    default:
      // Return everything
      return (200, makeResult(id: id, result: [
        "found": true,
        "profile": encodeToDict(profile)
      ]))
    }
  }

  // MARK: - Set

  private func handleSet(id: Any?, arguments: [String: Any], service: RepoProfileService) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "repoPath is required"))
    }

    guard let profileDict = arguments["profile"] as? [String: Any] else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "profile object is required"))
    }

    let shouldMerge = optionalBool("merge", from: arguments, default: false)

    do {
      let profileData: Data
      if shouldMerge, let existing = service.profile(for: repoPath) {
        // Merge: start with existing, overlay new values
        var existingDict = encodeToDict(existing) as? [String: Any] ?? [:]
        mergeDict(&existingDict, with: profileDict)
        profileData = try JSONSerialization.data(withJSONObject: existingDict)
      } else {
        profileData = try JSONSerialization.data(withJSONObject: profileDict)
      }

      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let profile = try decoder.decode(RepoProfile.self, from: profileData)
      try profile.save(to: repoPath)

      // Invalidate cache
      _ = service.reload(for: repoPath)

      logger.info("Saved repo profile for \(profile.name) at \(repoPath)")
      return (200, makeResult(id: id, result: [
        "saved": true,
        "name": profile.name,
        "path": "\(repoPath)/.peel/profile.json"
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Failed to save profile: \(error.localizedDescription)"))
    }
  }

  // MARK: - Generate

  private func handleGenerate(id: Any?, arguments: [String: Any], service: RepoProfileService) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "repoPath is required"))
    }

    let shouldSave = optionalBool("save", from: arguments, default: false)
    let fm = FileManager.default

    // Auto-detect repo characteristics
    var profile = RepoProfile(name: URL(fileURLWithPath: repoPath).lastPathComponent)

    // Detect package manager
    if fm.fileExists(atPath: "\(repoPath)/pnpm-lock.yaml") {
      profile.packageManager = .pnpm
      profile.installCommand = "pnpm install --frozen-lockfile"
    } else if fm.fileExists(atPath: "\(repoPath)/bun.lockb") || fm.fileExists(atPath: "\(repoPath)/bun.lock") {
      profile.packageManager = .bun
      profile.installCommand = "bun install"
    } else if fm.fileExists(atPath: "\(repoPath)/yarn.lock") {
      profile.packageManager = .yarn
      profile.installCommand = "yarn install --frozen-lockfile"
    } else if fm.fileExists(atPath: "\(repoPath)/package-lock.json") {
      profile.packageManager = .npm
      profile.installCommand = "npm ci"
    } else if fm.fileExists(atPath: "\(repoPath)/Cargo.toml") {
      profile.packageManager = .cargo
      profile.installCommand = "cargo build"
    } else if fm.fileExists(atPath: "\(repoPath)/Package.swift") {
      profile.packageManager = .swift
      profile.installCommand = "swift build"
    } else if fm.fileExists(atPath: "\(repoPath)/Gemfile.lock") {
      profile.packageManager = .bundler
      profile.installCommand = "bundle install"
    } else if fm.fileExists(atPath: "\(repoPath)/poetry.lock") {
      profile.packageManager = .poetry
      profile.installCommand = "poetry install"
    } else if fm.fileExists(atPath: "\(repoPath)/requirements.txt") {
      profile.packageManager = .pip
      profile.installCommand = "pip install -r requirements.txt"
    }

    // Detect apps (check for monorepo patterns)
    var apps: [AppDefinition] = []

    // Check for pnpm workspace (monorepo)
    if fm.fileExists(atPath: "\(repoPath)/pnpm-workspace.yaml") {
      profile.type = .monorepo
      // Scan immediate subdirs for package.json
      let contents = (try? fm.contentsOfDirectory(atPath: repoPath)) ?? []
      for item in contents.sorted() {
        let itemPath = "\(repoPath)/\(item)"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue,
           fm.fileExists(atPath: "\(itemPath)/package.json"),
           !item.starts(with: "."), item != "node_modules" {
          var app = AppDefinition(name: item, path: item)
          app = detectAppFramework(app, at: itemPath, fm: fm)
          apps.append(app)
        }
      }
      // Also check packages/ directory
      let packagesDir = "\(repoPath)/packages"
      var pkgIsDir: ObjCBool = false
      if fm.fileExists(atPath: packagesDir, isDirectory: &pkgIsDir), pkgIsDir.boolValue {
        let packages = (try? fm.contentsOfDirectory(atPath: packagesDir)) ?? []
        for pkg in packages.sorted() {
          let pkgPath = "\(packagesDir)/\(pkg)"
          if fm.fileExists(atPath: "\(pkgPath)/package.json") {
            var app = AppDefinition(name: pkg, path: "packages/\(pkg)")
            app = detectAppFramework(app, at: pkgPath, fm: fm)
            apps.append(app)
          }
        }
      }
    } else if fm.fileExists(atPath: "\(repoPath)/package.json") {
      // Single app
      profile.type = .singleApp
      var app = AppDefinition(name: profile.name, path: ".")
      app.isPrimary = true
      app = detectAppFramework(app, at: repoPath, fm: fm)
      apps.append(app)
    } else if fm.fileExists(atPath: "\(repoPath)/Package.swift") {
      profile.type = .library
    } else if fm.fileExists(atPath: "\(repoPath)/Cargo.toml") {
      profile.type = .singleApp
    }

    if !apps.isEmpty {
      // Mark first app as primary if none specified
      if !apps.contains(where: { $0.isPrimary == true }) {
        apps[0].isPrimary = true
      }
      profile.apps = apps
    }

    // Detect testing config
    var testing = TestingConfig()
    if fm.fileExists(atPath: "\(repoPath)/jest.config.js") || fm.fileExists(atPath: "\(repoPath)/jest.config.ts") {
      testing.framework = "jest"
      testing.testCommand = "\(profile.packageManager?.rawValue ?? "npm") test"
    } else if let pkgData = try? Data(contentsOf: URL(fileURLWithPath: "\(repoPath)/package.json")),
              let pkg = try? JSONSerialization.jsonObject(with: pkgData) as? [String: Any],
              let scripts = pkg["scripts"] as? [String: String] {
      if scripts["test"] != nil {
        testing.testCommand = "\(profile.packageManager?.rawValue ?? "npm") test"
      }
      if scripts["lint"] != nil {
        testing.lintCommand = "\(profile.packageManager?.rawValue ?? "npm") run lint"
      }
    }

    if fm.fileExists(atPath: "\(repoPath)/tests") || fm.fileExists(atPath: "\(repoPath)/test") {
      testing.testDirectory = fm.fileExists(atPath: "\(repoPath)/tests") ? "tests" : "test"
    }

    if testing.testCommand != nil || testing.lintCommand != nil {
      profile.testing = testing
    }

    // Detect conventions
    var conventions = ConventionsConfig()
    if fm.fileExists(atPath: "\(repoPath)/.nvmrc") {
      if let nvmrc = try? String(contentsOfFile: "\(repoPath)/.nvmrc", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
        conventions.languageVersions = ["node": nvmrc]
      }
    }
    if fm.fileExists(atPath: "\(repoPath)/.eslintrc.js") || fm.fileExists(atPath: "\(repoPath)/.eslintrc.json") || fm.fileExists(atPath: "\(repoPath)/eslint.config.js") {
      conventions.styleGuide = "ESLint configured — follow repo lint rules"
    }
    if fm.fileExists(atPath: "\(repoPath)/.prettierrc") || fm.fileExists(atPath: "\(repoPath)/.prettierrc.json") {
      let guide = (conventions.styleGuide ?? "") + "\nPrettier configured — code is auto-formatted"
      conventions.styleGuide = guide.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if conventions.languageVersions != nil || conventions.styleGuide != nil {
      profile.conventions = conventions
    }

    // Save if requested
    if shouldSave {
      do {
        try profile.save(to: repoPath)
        _ = service.reload(for: repoPath)
        logger.info("Generated and saved profile for \(profile.name)")
      } catch {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError,
          message: "Generated profile but failed to save: \(error.localizedDescription)"))
      }
    }

    return (200, makeResult(id: id, result: [
      "generated": true,
      "saved": shouldSave,
      "profile": encodeToDict(profile)
    ]))
  }

  // MARK: - Helpers

  /// Detect app framework from a package directory.
  private func detectAppFramework(_ app: AppDefinition, at path: String, fm: FileManager) -> AppDefinition {
    var app = app

    // Read package.json for clues
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(path)/package.json")),
          let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return app
    }

    let deps = (pkg["dependencies"] as? [String: Any]) ?? [:]
    let devDeps = (pkg["devDependencies"] as? [String: Any]) ?? [:]
    let allDeps = deps.merging(devDeps) { a, _ in a }
    let scripts = (pkg["scripts"] as? [String: String]) ?? [:]

    // Detect framework
    if allDeps["ember-source"] != nil || allDeps["ember-cli"] != nil {
      app.framework = "ember"
      app.devCommand = app.devCommand ?? (scripts["start"] != nil ? "pnpm start" : "pnpm dev")
      app.bootTimeSeconds = app.bootTimeSeconds ?? 60
    } else if allDeps["next"] != nil {
      app.framework = "next"
      app.devCommand = app.devCommand ?? "pnpm dev"
      app.bootTimeSeconds = app.bootTimeSeconds ?? 15
    } else if allDeps["react"] != nil {
      app.framework = allDeps["vite"] != nil ? "react-vite" : "react"
      app.devCommand = app.devCommand ?? "pnpm dev"
      app.bootTimeSeconds = app.bootTimeSeconds ?? 10
    } else if allDeps["vue"] != nil {
      app.framework = "vue"
      app.devCommand = app.devCommand ?? "pnpm dev"
      app.bootTimeSeconds = app.bootTimeSeconds ?? 10
    } else if allDeps["svelte"] != nil || allDeps["@sveltejs/kit"] != nil {
      app.framework = "svelte"
      app.devCommand = app.devCommand ?? "pnpm dev"
      app.bootTimeSeconds = app.bootTimeSeconds ?? 10
    } else if allDeps["express"] != nil || allDeps["fastify"] != nil || allDeps["koa"] != nil {
      app.framework = "node-api"
      app.devCommand = app.devCommand ?? "pnpm dev"
      app.bootTimeSeconds = app.bootTimeSeconds ?? 5
    }

    // Detect Vite config for port
    let viteConfigPaths = ["\(path)/vite.config.mjs", "\(path)/vite.config.js", "\(path)/vite.config.ts"]
    for configPath in viteConfigPaths {
      if fm.fileExists(atPath: configPath) {
        let relativePath = configPath.replacingOccurrences(of: "\(path)/", with: "")
        app.portConfigFile = relativePath
        app.portConfigPattern = "port:\\s*\\d+"

        // Try to extract the default port
        if let content = try? String(contentsOfFile: configPath, encoding: .utf8),
           let range = content.range(of: #"port:\s*(\d+)"#, options: .regularExpression) {
          let match = content[range]
          let digits = match.filter(\.isNumber)
          if let port = Int(digits) {
            app.defaultPort = port
          }
        }
        break
      }
    }

    return app
  }

  /// Encode a Codable value to a JSON-compatible dictionary.
  private func encodeToDict<T: Encodable>(_ value: T) -> Any {
    do {
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      let data = try encoder.encode(value)
      return try JSONSerialization.jsonObject(with: data)
    } catch {
      return ["error": "Failed to encode: \(error.localizedDescription)"]
    }
  }

  /// Merge two dictionaries recursively.
  private func mergeDict(_ base: inout [String: Any], with overlay: [String: Any]) {
    for (key, value) in overlay {
      if let existingDict = base[key] as? [String: Any],
         let overlayDict = value as? [String: Any] {
        var merged = existingDict
        mergeDict(&merged, with: overlayDict)
        base[key] = merged
      } else {
        base[key] = value
      }
    }
  }
}
