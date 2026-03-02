import Foundation
import MCPCore

// MARK: - RepoToolsHandler

@MainActor
protocol RepoToolsHandlerDelegate: MCPToolHandlerDelegate {
  var repoDataService: DataService? { get }
}

@MainActor
final class RepoToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?

  private var repoDelegate: RepoToolsHandlerDelegate? {
    delegate as? RepoToolsHandlerDelegate
  }

  let supportedTools: Set<String> = [
    "repos.list",
    "repos.resolve",
    "repos.delete",
    "repos.track",
    "repos.untrack",
    "repos.tracked",
    "repos.pull-now"
  ]

  private struct RepoToolRepository {
    let id: UUID
    let name: String
    let localPath: String?
    let remoteURL: String?
    let isFavorite: Bool
    let isValid: Bool
    let createdAt: Date
    let modifiedAt: Date
    let lastAccessedAt: Date?
    let hasBookmark: Bool

    func dictionary(selectedId: UUID?, formatter: ISO8601DateFormatter) -> [String: Any] {
      var result: [String: Any] = [
        "id": id.uuidString,
        "name": name,
        "isFavorite": isFavorite,
        "isValid": isValid,
        "isSelected": selectedId == id,
        "createdAt": formatter.string(from: createdAt),
        "modifiedAt": formatter.string(from: modifiedAt),
        "hasBookmark": hasBookmark
      ]
      if let localPath {
        result["localPath"] = localPath
      }
      if let remoteURL {
        result["remoteURL"] = remoteURL
      }
      if let lastAccessedAt {
        result["lastAccessedAt"] = formatter.string(from: lastAccessedAt)
      }
      return result
    }
  }

  private enum MatchMode: String {
    case exact
    case contains
    case pathSuffix
  }

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let repoDelegate else {
      return notConfiguredError(id: id)
    }

    switch name {
    case "repos.list":
      return handleList(id: id, arguments: arguments, delegate: repoDelegate)
    case "repos.resolve":
      return handleResolve(id: id, arguments: arguments, delegate: repoDelegate)
    case "repos.delete":
      return await handleDelete(id: id, arguments: arguments, delegate: repoDelegate)
    case "repos.track":
      return handleTrack(id: id, arguments: arguments, delegate: repoDelegate)
    case "repos.untrack":
      return handleUntrack(id: id, arguments: arguments, delegate: repoDelegate)
    case "repos.tracked":
      return handleTracked(id: id, arguments: arguments, delegate: repoDelegate)
    case "repos.pull-now":
      return await handlePullNow(id: id, arguments: arguments, delegate: repoDelegate)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown repo tool: \(name)"))
    }
  }

  private func handleList(id: Any?, arguments: [String: Any], delegate: RepoToolsHandlerDelegate) -> (Int, Data) {
    let includeInvalid = optionalBool("includeInvalid", from: arguments, default: true)
    guard let dataService = delegate.repoDataService else {
      return notConfiguredError(id: id)
    }

    let (repos, selectedId) = loadRepositories(from: dataService, includeInvalid: includeInvalid)
    let formatter = Formatter.iso8601
    let encoded = repos.map { $0.dictionary(selectedId: selectedId, formatter: formatter) }

    return (200, makeResult(id: id, result: [
      "count": encoded.count,
      "selectedRepositoryId": selectedId?.uuidString as Any,
      "repositories": encoded
    ]))
  }

  private func handleResolve(id: Any?, arguments: [String: Any], delegate: RepoToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let name) = requireString("name", from: arguments, id: id) else {
      return missingParamError(id: id, param: "name")
    }

    let includeInvalid = optionalBool("includeInvalid", from: arguments, default: true)
    let matchRaw = optionalString("match", from: arguments, default: MatchMode.exact.rawValue) ?? MatchMode.exact.rawValue
    let matchMode = MatchMode(rawValue: matchRaw) ?? .exact

    guard let dataService = delegate.repoDataService else {
      return notConfiguredError(id: id)
    }

    let (repos, selectedId) = loadRepositories(from: dataService, includeInvalid: includeInvalid)
    let matches = filterRepositories(repos, by: name, mode: matchMode)
    let formatter = Formatter.iso8601
    let encodedMatches = matches.map { $0.dictionary(selectedId: selectedId, formatter: formatter) }

    var result: [String: Any] = [
      "count": encodedMatches.count,
      "resolved": encodedMatches.count == 1,
      "selectedRepositoryId": selectedId?.uuidString as Any,
      "matches": encodedMatches
    ]

    if let resolved = encodedMatches.first, encodedMatches.count == 1 {
      result["repository"] = resolved
    }

    return (200, makeResult(id: id, result: result))
  }

  private func loadRepositories(from dataService: DataService, includeInvalid: Bool) -> ([RepoToolRepository], UUID?) {
    let repos = dataService.getAllRepositories()
    let selectedId = dataService.getSelectedRepository()?.id

    let items = repos.compactMap { repo -> RepoToolRepository? in
      let localPath = dataService.getLocalPath(for: repo)
      let path = localPath?.localPath
      let isValid = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
      if !includeInvalid, !isValid {
        return nil
      }

      return RepoToolRepository(
        id: repo.id,
        name: repo.name,
        localPath: path,
        remoteURL: repo.remoteURL,
        isFavorite: repo.isFavorite,
        isValid: isValid,
        createdAt: repo.createdAt,
        modifiedAt: repo.modifiedAt,
        lastAccessedAt: localPath?.lastAccessedAt,
        hasBookmark: localPath?.bookmarkData != nil
      )
    }

    return (items, selectedId)
  }

  private func filterRepositories(
    _ repositories: [RepoToolRepository],
    by name: String,
    mode: MatchMode
  ) -> [RepoToolRepository] {
    let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return [] }

    return repositories.filter { repo in
      let repoName = repo.name.lowercased()
      let pathName = repo.localPath?.split(separator: "/").last?.lowercased() ?? ""

      switch mode {
      case .exact:
        return repoName == needle || pathName == needle
      case .contains:
        return repoName.contains(needle) || pathName.contains(needle)
      case .pathSuffix:
        guard let localPath = repo.localPath?.lowercased() else { return false }
        return localPath.hasSuffix("/\(needle)")
      }
    }
  }

  private func handleDelete(id: Any?, arguments: [String: Any], delegate: RepoToolsHandlerDelegate) async -> (Int, Data) {
    let repoIdString = optionalString("repoId", from: arguments)
    let localPath = optionalString("localPath", from: arguments)

    guard repoIdString != nil || localPath != nil else {
      return missingParamError(id: id, param: "repoId or localPath")
    }

    guard let dataService = delegate.repoDataService else {
      return notConfiguredError(id: id)
    }

    let repos = dataService.getAllRepositories()
    var toDelete: SyncedRepository?

    if let repoIdString, let repoId = UUID(uuidString: repoIdString) {
      toDelete = repos.first { $0.id == repoId }
    } else if let localPath {
      toDelete = repos.first { repo in
        dataService.getLocalPath(for: repo)?.localPath == localPath
      }
    }

    guard let repository = toDelete else {
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Repository not found"))
    }

    let repoName = repository.name

    // Delete from SwiftData
    dataService.deleteRepository(repository)

    let result: [String: Any] = [
      "deleted": true,
      "repositoryName": repoName
    ]

    return (200, makeResult(id: id, result: result))
  }

  // MARK: - Tracked Remote Repo Handlers

  private func handleTrack(id: Any?, arguments: [String: Any], delegate: RepoToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let localPath) = requireString("localPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "localPath")
    }

    guard let dataService = delegate.repoDataService else {
      return notConfiguredError(id: id)
    }

    guard FileManager.default.fileExists(atPath: localPath) else {
      return internalError(id: id, message: "Path does not exist: \(localPath)")
    }

    // Try to get remote URL from arguments or discover it
    let remoteURL: String
    if let explicit = optionalString("remoteURL", from: arguments) {
      remoteURL = explicit
    } else if let cached = RepoRegistry.shared.getCachedRemoteURL(for: localPath) {
      remoteURL = cached
    } else {
      return internalError(id: id, message: "Could not determine remote URL. Provide remoteURL explicitly or ensure the path is a git repo with a remote.")
    }

    let name = optionalString("name", from: arguments) ?? URL(fileURLWithPath: localPath).lastPathComponent
    let branch = optionalString("branch", from: arguments, default: "main") ?? "main"
    let remoteName = optionalString("remoteName", from: arguments, default: "origin") ?? "origin"
    let intervalSeconds = optionalInt("pullIntervalSeconds", from: arguments) ?? 3600
    let reindexAfterPull = optionalBool("reindexAfterPull", from: arguments, default: true)

    let tracked = dataService.trackRemoteRepo(
      remoteURL: remoteURL,
      name: name,
      localPath: localPath,
      branch: branch,
      remoteName: remoteName,
      pullIntervalSeconds: intervalSeconds,
      reindexAfterPull: reindexAfterPull
    )

    let formatter = Formatter.iso8601
    return (200, makeResult(id: id, result: [
      "success": true,
      "id": tracked.id.uuidString,
      "name": tracked.name,
      "remoteURL": tracked.remoteURL,
      "localPath": tracked.localPath,
      "branch": tracked.branch,
      "remoteName": tracked.remoteName,
      "pullIntervalSeconds": tracked.pullIntervalSeconds,
      "reindexAfterPull": tracked.reindexAfterPull,
      "isEnabled": tracked.isEnabled,
      "createdAt": formatter.string(from: tracked.createdAt)
    ]))
  }

  private func handleUntrack(id: Any?, arguments: [String: Any], delegate: RepoToolsHandlerDelegate) -> (Int, Data) {
    guard let dataService = delegate.repoDataService else {
      return notConfiguredError(id: id)
    }

    if let remoteURL = optionalString("remoteURL", from: arguments) {
      let deleted = dataService.untrackRemoteRepo(remoteURL: remoteURL)
      return (200, makeResult(id: id, result: ["deleted": deleted, "remoteURL": remoteURL]))
    }

    if let idString = optionalString("id", from: arguments), let repoId = UUID(uuidString: idString) {
      let deleted = dataService.untrackRemoteRepo(id: repoId)
      return (200, makeResult(id: id, result: ["deleted": deleted, "id": idString]))
    }

    return missingParamError(id: id, param: "remoteURL or id")
  }

  private func handleTracked(id: Any?, arguments: [String: Any], delegate: RepoToolsHandlerDelegate) -> (Int, Data) {
    guard let dataService = delegate.repoDataService else {
      return notConfiguredError(id: id)
    }

    let tracked = dataService.getTrackedRemoteRepos()
    let formatter = Formatter.iso8601

    let encoded: [[String: Any]] = tracked.map { repo in
      var entry: [String: Any] = [
        "id": repo.id.uuidString,
        "name": repo.name,
        "remoteURL": repo.remoteURL,
        "localPath": repo.localPath,
        "branch": repo.branch,
        "remoteName": repo.remoteName,
        "pullIntervalSeconds": repo.pullIntervalSeconds,
        "isEnabled": repo.isEnabled,
        "reindexAfterPull": repo.reindexAfterPull,
        "isPullDue": repo.isPullDue,
        "createdAt": formatter.string(from: repo.createdAt),
        "modifiedAt": formatter.string(from: repo.modifiedAt)
      ]
      if let lastPull = repo.lastPullAt {
        entry["lastPullAt"] = formatter.string(from: lastPull)
      }
      if let result = repo.lastPullResult {
        entry["lastPullResult"] = result
      }
      if let error = repo.lastPullError {
        entry["lastPullError"] = error
      }
      return entry
    }

    let scheduler = RepoPullScheduler.shared
    return (200, makeResult(id: id, result: [
      "count": encoded.count,
      "schedulerActive": scheduler.isActive,
      "repos": encoded
    ]))
  }

  private func handlePullNow(id: Any?, arguments: [String: Any], delegate: RepoToolsHandlerDelegate) async -> (Int, Data) {
    let scheduler = RepoPullScheduler.shared

    // If a specific repo is specified, pull just that one
    if let remoteURL = optionalString("remoteURL", from: arguments) {
      guard let result = await scheduler.pullRepoNow(remoteURL: remoteURL) else {
        return internalError(id: id, message: "Repo not found in tracked list: \(remoteURL)")
      }
      return (200, makeResult(id: id, result: [
        "remoteURL": remoteURL,
        "result": result.description,
        "success": !result.isError
      ]))
    }

    // Otherwise, pull all due repos
    await scheduler.pullDueRepos()
    let history = scheduler.pullHistory.prefix(10)
    let formatter = Formatter.iso8601
    let entries: [[String: Any]] = history.map {
      [
        "repoName": $0.repoName,
        "result": $0.result,
        "success": $0.success,
        "timestamp": formatter.string(from: $0.timestamp)
      ]
    }

    return (200, makeResult(id: id, result: [
      "pulled": true,
      "recentHistory": entries
    ]))
  }
}

// MARK: - Tool Definitions

extension RepoToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "repos.list",
        description: "List git repositories tracked in Peel on this device",
        inputSchema: [
          "type": "object",
          "properties": [
            "includeInvalid": ["type": "boolean", "default": true]
          ]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "repos.resolve",
        description: "Resolve repositories by name (exact, contains, or pathSuffix match)",
        inputSchema: [
          "type": "object",
          "properties": [
            "name": ["type": "string"],
            "match": ["type": "string", "enum": ["exact", "contains", "pathSuffix"], "default": "exact"],
            "includeInvalid": ["type": "boolean", "default": true]
          ],
          "required": ["name"]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "repos.delete",
        description: "Delete a repository from Peel's SwiftData store by repoId or localPath",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoId": ["type": "string", "description": "Repository UUID to delete"],
            "localPath": ["type": "string", "description": "Local path of repository to delete"]
          ]
        ],
        category: .state,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "repos.track",
        description: "Mark a repo as primary/tracked for automatic periodic git pull. The scheduler will pull the latest changes on the specified branch at the given interval (default: hourly) and optionally re-index the RAG.",
        inputSchema: [
          "type": "object",
          "properties": [
            "localPath": ["type": "string", "description": "Local path to the git repository"],
            "remoteURL": ["type": "string", "description": "Git remote URL (auto-detected if omitted)"],
            "name": ["type": "string", "description": "Display name (defaults to directory name)"],
            "branch": ["type": "string", "default": "main", "description": "Branch to track"],
            "remoteName": ["type": "string", "default": "origin", "description": "Git remote name"],
            "pullIntervalSeconds": ["type": "integer", "default": 3600, "description": "Pull interval in seconds (default: 3600 = 1 hour)"],
            "reindexAfterPull": ["type": "boolean", "default": true, "description": "Re-index RAG after pulling new changes"]
          ],
          "required": ["localPath"]
        ],
        category: .state,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "repos.untrack",
        description: "Remove a repo from the tracked/primary list, stopping automatic pulls",
        inputSchema: [
          "type": "object",
          "properties": [
            "remoteURL": ["type": "string", "description": "Remote URL of the repo to untrack"],
            "id": ["type": "string", "description": "UUID of the tracked repo to remove"]
          ]
        ],
        category: .state,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "repos.tracked",
        description: "List all repos marked as primary/tracked for automatic pulls, including their status and schedule",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .state,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "repos.pull-now",
        description: "Immediately pull a tracked repo (or all due repos if no remoteURL specified)",
        inputSchema: [
          "type": "object",
          "properties": [
            "remoteURL": ["type": "string", "description": "Pull a specific tracked repo by remote URL. If omitted, pulls all due repos."]
          ]
        ],
        category: .state,
        isMutating: true
      ),
    ]
  }
}
