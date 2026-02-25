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
    "repos.delete"
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
    ]
  }
}
