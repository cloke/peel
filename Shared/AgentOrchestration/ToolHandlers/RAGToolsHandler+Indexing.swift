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
import OSLog

extension RAGToolsHandler {
  // MARK: - rag.status
  
  func handleStatus(id: Any?, delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let status = await delegate.ragStatus()
    let formatter = Formatter.iso8601
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
      let formatter = Formatter.iso8601
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
      let indexTimer = MainThreadBlockTimer(
        label: "rag.index indexRepository(\(repoPath))",
        logger: Logger(subsystem: "com.peel.diagnostics", category: "MainThreadWatchdog")
      )
      let report = try await delegate.indexRepository(
        path: repoPath,
        forceReindex: forceReindex,
        allowWorkspace: allowWorkspace,
        excludeSubrepos: excludeSubrepos,
        progressHandler: nil
      )
      indexTimer.finish()
      
      await delegate.refreshRagSummary()

      // Publish index version to Firestore for P2P sharing
      await publishIndexVersionAfterIndex(report: report, delegate: delegate)

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
      let formatter = Formatter.iso8601
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

  // MARK: - Index Version Publishing

  /// Publish index version to Firestore after a successful rag.index.
  /// This enables other swarm members to discover and request the index via P2P.
  private static let publishLogger = Logger(subsystem: "com.peel.rag", category: "IndexPublish")

  private func publishIndexVersionAfterIndex(
    report: RAGToolIndexReport,
    delegate: RAGToolsHandlerDelegate
  ) async {
    // Only publish if there's something meaningful
    guard report.chunksIndexed > 0 || report.embeddingCount > 0 else {
      Self.publishLogger.debug("Skipping publish: no chunks or embeddings in report")
      return
    }

    do {
      // Look up the repo to get its identifier (git remote URL)
      let repos = try await delegate.listRagRepos()
      guard let repo = repos.first(where: { $0.rootPath == report.repoPath || $0.id == report.repoId }) else {
        Self.publishLogger.warning("Skipping publish: no matching repo found for path=\(report.repoPath) id=\(report.repoId)")
        return
      }
      guard let repoIdentifier = repo.repoIdentifier else {
        Self.publishLogger.warning("Skipping publish: repo \(repo.name) has no repoIdentifier (no git remote?)")
        return
      }

      // Get current RAG status for embedding model info
      let status = await delegate.ragStatus()

      // Resolve HEAD SHA from the repo path
      let headSHA = await resolveHeadSHA(at: report.repoPath)

      Self.publishLogger.info("Publishing index version for \(repo.name) (\(repoIdentifier))")
      await RAGSyncCoordinator.shared.publishVersion(
        repoIdentifier: repoIdentifier,
        repoName: repo.name,
        headSHA: headSHA,
        fileCount: repo.fileCount,
        chunkCount: repo.chunkCount,
        embeddingModel: status.embeddingModelName,
        embeddingDimensions: status.embeddingDimensions,
        sizeEstimateBytes: report.bytesScanned
      )
    } catch {
      Self.publishLogger.warning("Failed to publish index version: \(error.localizedDescription)")
    }
  }

  // MARK: - rag.publish

  /// Manually publish a locally-indexed repo's version to Firestore for swarm discovery.
  /// Use when auto-publish after rag.index didn't fire (e.g., repo was indexed before joining a swarm).
  func handlePublish(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let repoIdentifierArg = optionalString("repoIdentifier", from: arguments)

    do {
      let repos = try await delegate.listRagRepos()

      // Find matching repo(s)
      let matchingRepos: [RAGToolRepoInfo]
      if let repoPath {
        matchingRepos = repos.filter { $0.rootPath == repoPath }
      } else if let repoIdentifierArg {
        matchingRepos = repos.filter { $0.repoIdentifier == repoIdentifierArg }
      } else {
        // Publish all repos that have a repoIdentifier
        matchingRepos = repos.filter { $0.repoIdentifier != nil }
      }

      guard !matchingRepos.isEmpty else {
        return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "No indexed repos found matching the criteria. Use rag.repos.list to see available repos."))
      }

      let firebase = FirebaseService.shared
      guard firebase.isSignedIn else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Not signed in to Firebase. Sign in first to publish index versions."))
      }

      let eligibleSwarms = firebase.memberSwarms.filter { $0.role.canRegisterWorkers }
      guard !eligibleSwarms.isEmpty else {
        let roles = firebase.memberSwarms.map { "\($0.swarmName): \($0.role.rawValue)" }.joined(separator: ", ")
        let msg = firebase.memberSwarms.isEmpty
          ? "Not a member of any swarm. Join a swarm first."
          : "No swarm membership with publish permission (need contributor+). Current: \(roles)"
        return (403, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: msg))
      }

      let status = await delegate.ragStatus()
      var published: [[String: Any]] = []

      for repo in matchingRepos {
        guard let repoIdentifier = repo.repoIdentifier else { continue }
        let headSHA = await resolveHeadSHA(at: repo.rootPath)

        await RAGSyncCoordinator.shared.publishVersion(
          repoIdentifier: repoIdentifier,
          repoName: repo.name,
          headSHA: headSHA,
          fileCount: repo.fileCount,
          chunkCount: repo.chunkCount,
          embeddingModel: status.embeddingModelName,
          embeddingDimensions: status.embeddingDimensions,
          sizeEstimateBytes: 0
        )
        published.append([
          "repoIdentifier": repoIdentifier,
          "repoName": repo.name,
          "fileCount": repo.fileCount,
          "chunkCount": repo.chunkCount,
          "swarms": eligibleSwarms.map { $0.swarmName },
        ])
      }

      return (200, makeResult(id: id, result: [
        "published": published.count,
        "repos": published,
        "swarms": eligibleSwarms.map { ["id": $0.id, "name": $0.swarmName, "role": $0.role.rawValue] },
      ]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to publish: \(error.localizedDescription)"))
    }
  }

  private func resolveHeadSHA(at repoPath: String) async -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "HEAD"]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

}
