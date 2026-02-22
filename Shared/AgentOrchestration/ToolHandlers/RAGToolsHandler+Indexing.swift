//
//  RAGToolsHandler+Indexing.swift
//  Peel
//
//  Handles: rag.status, rag.init, rag.index, rag.repos.list,
//           rag.repos.delete, rag.branch.index, rag.branch.cleanup
//  Split from RAGToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension RAGToolsHandler {
  // MARK: - rag.status
  
  func handleStatus(id: Any?, delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let status = await delegate.ragStatus()
    let formatter = ISO8601DateFormatter()
    var result: [String: Any] = [
      "dbPath": status.dbPath,
      "exists": status.exists,
      "schemaVersion": status.schemaVersion,
      "extensionLoaded": status.extensionLoaded,
      "embeddingProvider": status.providerName,
      "embeddingModel": status.embeddingModelName,
      "embeddingDimensions": status.embeddingDimensions,
      "debugForceSystem": UserDefaults.standard.bool(forKey: "localrag.useSystem")
    ]
    if let lastInitializedAt = status.lastInitializedAt {
      result["lastInitializedAt"] = formatter.string(from: lastInitializedAt)
    }
    return (200, makeResult(id: id, result: result))
  }

  // MARK: - rag.init

  func handleInit(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let extensionPath = optionalString("extensionPath", from: arguments)

    do {
      let status = try await delegate.initializeRag(extensionPath: extensionPath)
      await delegate.refreshRagSummary()
      let formatter = ISO8601DateFormatter()
      var result: [String: Any] = [
        "dbPath": status.dbPath,
        "exists": status.exists,
        "schemaVersion": status.schemaVersion,
        "extensionLoaded": status.extensionLoaded,
        "embeddingProvider": status.providerName,
        "embeddingModel": status.embeddingModelName,
        "embeddingDimensions": status.embeddingDimensions
      ]
      if let lastInitializedAt = status.lastInitializedAt {
        result["lastInitializedAt"] = formatter.string(from: lastInitializedAt)
      }
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("Local RAG init failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.index
  
  func handleIndex(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let forceReindex = optionalBool("forceReindex", from: arguments, default: false)
    let allowWorkspace = optionalBool("allowWorkspace", from: arguments, default: false)
    let excludeSubrepos = optionalBool("excludeSubrepos", from: arguments, default: true)
    
    do {
      // Delegate handles all state tracking
      let report = try await delegate.indexRepository(
        path: repoPath,
        forceReindex: forceReindex,
        allowWorkspace: allowWorkspace,
        excludeSubrepos: excludeSubrepos,
        progressHandler: nil
      )
      
      await delegate.refreshRagSummary()
      
      var result: [String: Any] = [
        "repoId": report.repoId,
        "repoPath": report.repoPath,
        "filesIndexed": report.filesIndexed,
        "filesSkipped": report.filesSkipped,
        "filesRemoved": report.filesRemoved,
        "chunksIndexed": report.chunksIndexed,
        "bytesScanned": report.bytesScanned,
        "durationMs": report.durationMs,
        "embeddingCount": report.embeddingCount,
        "embeddingDurationMs": report.embeddingDurationMs
      ]
      // Include sub-package reports for workspace indexing (#262)
      if !report.subReports.isEmpty {
        result["subPackagesIndexed"] = report.subReports.count
        result["subReports"] = report.subReports.map { sub -> [String: Any] in
          [
            "repoId": sub.repoId,
            "repoPath": sub.repoPath,
            "filesIndexed": sub.filesIndexed,
            "filesSkipped": sub.filesSkipped,
            "chunksIndexed": sub.chunksIndexed
          ]
        }
      }
      return (200, makeResult(id: id, result: result))
    } catch {
      await delegate.logWarning("Local RAG index failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.repos.list
  
  func handleReposList(id: Any?, delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    do {
      let repos = try await delegate.listRagRepos()
      let formatter = ISO8601DateFormatter()
      let repoList = repos.map { repo -> [String: Any] in
        var dict: [String: Any] = [
          "id": repo.id,
          "name": repo.name,
          "rootPath": repo.rootPath,
          "fileCount": repo.fileCount,
          "chunkCount": repo.chunkCount
        ]
        if let lastIndexedAt = repo.lastIndexedAt {
          dict["lastIndexedAt"] = formatter.string(from: lastIndexedAt)
        }
        if let repoIdentifier = repo.repoIdentifier {
          dict["repoIdentifier"] = repoIdentifier
        }
        if let parentRepoId = repo.parentRepoId {
          dict["parentRepoId"] = parentRepoId
          // Find the parent repo name for readability
          if let parent = repos.first(where: { $0.id == parentRepoId }) {
            dict["parentName"] = parent.name
          }
        }
        if let embeddingModel = repo.embeddingModel {
          dict["embeddingModel"] = embeddingModel
        }
        if let embeddingDimensions = repo.embeddingDimensions {
          dict["embeddingDimensions"] = embeddingDimensions
        }
        return dict
      }
      return (200, makeResult(id: id, result: ["repos": repoList]))
    } catch {
      await delegate.logWarning("Local RAG list repos failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.repos.delete
  
  func handleReposDelete(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoId = optionalString("repoId", from: arguments)
    let repoPath = optionalString("repoPath", from: arguments)
    
    guard repoId != nil || repoPath != nil else {
      return missingParamError(id: id, param: "repoId or repoPath")
    }
    
    do {
      let deletedCount = try await delegate.deleteRagRepo(repoId: repoId, repoPath: repoPath)
      await delegate.refreshRagSummary()
      return (200, makeResult(id: id, result: ["filesDeleted": deletedCount]))
    } catch {
      await delegate.logWarning("Local RAG delete repo failed", metadata: ["error": error.localizedDescription])
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.branch.index (Issue #260)

  func handleBranchIndex(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate?) async -> (Int, Data) {
    guard let delegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "RAG delegate unavailable"))
    }
    guard let repoPath = optionalString("repoPath", from: arguments) else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "repoPath is required"))
    }
    let baseBranch = optionalString("baseBranch", from: arguments) ?? "main"
    let baseRepoPath = optionalString("baseRepoPath", from: arguments)

    do {
      let result = try await delegate.indexBranchRepository(
        repoPath: repoPath,
        baseBranch: baseBranch,
        baseRepoPath: baseRepoPath,
        progressHandler: nil
      )
      let report = result.report
      var payload: [String: Any] = [
        "repoId": report.repoId,
        "repoPath": report.repoPath,
        "filesIndexed": report.filesIndexed,
        "filesSkipped": report.filesSkipped,
        "chunksIndexed": report.chunksIndexed,
        "bytesScanned": report.bytesScanned,
        "durationMs": report.durationMs,
        "embeddingCount": report.embeddingCount,
        "changedFilesCount": result.changedFilesCount,
        "deletedFilesCount": result.deletedFilesCount,
        "wasCopiedFromBase": result.wasCopiedFromBase,
      ]
      if let base = result.baseRepoPath {
        payload["baseRepoPath"] = base
      }
      return (200, makeResult(id: id, result: payload))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

  // MARK: - rag.branch.cleanup (Issue #260)

  func handleBranchCleanup(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate?) async -> (Int, Data) {
    guard let delegate else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "RAG delegate unavailable"))
    }
    let dryRun = optionalBool("dryRun", from: arguments, default: false)

    do {
      let result = try await delegate.cleanupBranchIndexes(dryRun: dryRun)
      return (200, makeResult(id: id, result: [
        "removedCount": result.removedCount,
        "removedPaths": result.removedPaths,
        "dryRun": dryRun,
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }

}
