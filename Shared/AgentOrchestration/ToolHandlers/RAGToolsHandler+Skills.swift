//
//  RAGToolsHandler+Skills.swift
//  Peel
//
//  Handles: rag.skills.list, .add, .update, .delete, .export,
//           .import, .sync, .ember.detect, .ember.update
//  Split from RAGToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore
import SwiftData

extension RAGToolsHandler {
  // MARK: - rag.skills.list
  
  func handleSkillsList(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments)
    let repoRemoteURL = optionalString("repoRemoteURL", from: arguments)
    let includeInactive = optionalBool("includeInactive", from: arguments, default: false)
    let limit = optionalInt("limit", from: arguments)
    let formatter = ISO8601DateFormatter()
    
    let skills = delegate.listRepoGuidanceSkills(
      repoPath: repoPath?.isEmpty == false ? repoPath : nil,
      repoRemoteURL: repoRemoteURL?.isEmpty == false ? repoRemoteURL : nil,
      includeInactive: includeInactive,
      limit: limit
    )
    let payload = skills.map { encodeSkill($0, formatter: formatter) }
    return (200, makeResult(id: id, result: ["skills": payload]))
  }
  
  // MARK: - rag.skills.add
  
  func handleSkillsAdd(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    let repoPath = optionalString("repoPath", from: arguments) ?? "*"
    guard case .success(let title) = requireString("title", from: arguments, id: id) else {
      return missingParamError(id: id, param: "title")
    }
    guard case .success(let body) = requireString("body", from: arguments, id: id) else {
      return missingParamError(id: id, param: "body")
    }
    
    let repoRemoteURL = optionalString("repoRemoteURL", from: arguments)
    let repoName = optionalString("repoName", from: arguments)
    let source = optionalString("source", from: arguments, default: "manual") ?? "manual"
    let tags = optionalString("tags", from: arguments, default: "") ?? ""
    let priority = optionalInt("priority", from: arguments, default: 0) ?? 0
    let isActive = optionalBool("isActive", from: arguments, default: true)
    
    let skill = delegate.addRepoGuidanceSkill(
      repoPath: repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "*" : repoPath,
      repoRemoteURL: repoRemoteURL,
      repoName: repoName,
      title: title,
      body: body,
      source: source,
      tags: tags,
      priority: priority,
      isActive: isActive
    )
    guard let skill else {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to create skill"))
    }
    let formatter = ISO8601DateFormatter()
    return (200, makeResult(id: id, result: ["skill": encodeSkill(skill, formatter: formatter)]))
  }
  
  // MARK: - rag.skills.update
  
  func handleSkillsUpdate(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let skillId) = requireUUID("skillId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "skillId")
    }
    
    let skill = delegate.updateRepoGuidanceSkill(
      id: skillId,
      repoPath: optionalString("repoPath", from: arguments),
      repoRemoteURL: optionalString("repoRemoteURL", from: arguments),
      repoName: optionalString("repoName", from: arguments),
      title: optionalString("title", from: arguments),
      body: optionalString("body", from: arguments),
      source: optionalString("source", from: arguments),
      tags: optionalString("tags", from: arguments),
      priority: optionalInt("priority", from: arguments),
      isActive: arguments["isActive"] as? Bool
    )
    
    guard let skill else {
      return notFoundError(id: id, what: "Skill")
    }
    let formatter = ISO8601DateFormatter()
    return (200, makeResult(id: id, result: ["skill": encodeSkill(skill, formatter: formatter)]))
  }
  
  // MARK: - rag.skills.delete
  
  func handleSkillsDelete(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let skillId) = requireUUID("skillId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "skillId")
    }
    
    let deleted = delegate.deleteRepoGuidanceSkill(id: skillId)
    if !deleted {
      return notFoundError(id: id, what: "Skill")
    }
    return (200, makeResult(id: id, result: ["deleted": skillId.uuidString]))
  }

  // MARK: - rag.skills.export (#264)

  func handleSkillsExport(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    do {
      let (count, path) = try delegate.exportSkillsToFile(repoPath: repoPath)
      return (200, makeResult(id: id, result: ["exported": count, "path": path]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Export failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - rag.skills.import (#264)

  func handleSkillsImport(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    do {
      let (imported, skipped) = try delegate.importSkillsFromFile(repoPath: repoPath)
      return (200, makeResult(id: id, result: ["imported": imported, "skipped": skipped]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Import failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - rag.skills.sync (#264)

  func handleSkillsSync(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    do {
      let (exported, imported, path) = try delegate.syncSkillsWithFile(repoPath: repoPath)
      return (200, makeResult(id: id, result: ["exported": exported, "imported": imported, "path": path]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Sync failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - rag.skills.ember.detect (#263)
  
  func handleSkillsEmberDetect(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let isEmber = DefaultSkillsService.detectEmberProject(repoPath: repoPath)
    let alreadySeeded = DefaultSkillsService.hasLoadedEmberSkills(repoPath: repoPath)
    let skillCount = delegate.listRepoGuidanceSkills(repoPath: repoPath, repoRemoteURL: nil, includeInactive: false, limit: nil)
      .filter { $0.source == "NullVoxPopuli/agent-skills" }
      .count
    
    var result: [String: Any] = [
      "isEmberProject": isEmber,
      "alreadySeeded": alreadySeeded,
      "emberSkillCount": skillCount
    ]
    
    // If Ember and not seeded, offer to seed
    if isEmber && !alreadySeeded {
      result["action"] = "Use rag.skills.ember.update with action='seed' to add Ember best practices"
    }
    
    // Check for bundle info
    if let bundle = DefaultSkillsService.loadEmberSkillsBundle() {
      result["bundledVersion"] = bundle.meta.version
      result["bundledSkillCount"] = bundle.skills.count
      result["source"] = bundle.meta.source
    }
    
    return (200, makeResult(id: id, result: result))
  }
  
  // MARK: - rag.skills.ember.update (#263)
  
  func handleSkillsEmberUpdate(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let action = optionalString("action", from: arguments) ?? "check"
    
    switch action {
    case "check":
      // Check for updates from GitHub
      let result = await SkillUpdateService.shared.checkForEmberSkillsUpdate(force: true)
      var response: [String: Any] = [
        "hasUpdate": result.hasUpdate,
        "currentVersion": result.currentVersion ?? "unknown"
      ]
      if let sha = result.latestCommitSHA {
        response["latestCommitSHA"] = String(sha.prefix(8))
      }
      if let lastUpdated = result.lastUpdated {
        response["lastChecked"] = ISO8601DateFormatter().string(from: lastUpdated)
      }
      if let error = result.error {
        response["error"] = error.localizedDescription
      }
      return (200, makeResult(id: id, result: response))
      
    case "seed":
      // Seed Ember skills for this repo
      guard let context = delegate.modelContext else {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Model context not available"))
      }
      
      let isEmber = DefaultSkillsService.detectEmberProject(repoPath: repoPath)
      if !isEmber {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Not an Ember project: \(repoPath)"))
      }
      
      let count = DefaultSkillsService.seedEmberSkills(context: context, repoPath: repoPath, force: true)
      return (200, makeResult(id: id, result: [
        "seeded": count,
        "repoPath": repoPath,
        "source": "NullVoxPopuli/agent-skills"
      ]))
      
    case "update":
      // Remove old and seed new
      guard let context = delegate.modelContext else {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Model context not available"))
      }
      
      let count = DefaultSkillsService.updateEmberSkills(context: context, repoPath: repoPath)
      return (200, makeResult(id: id, result: [
        "updated": count,
        "repoPath": repoPath,
        "source": "NullVoxPopuli/agent-skills"
      ]))
      
    case "remove":
      // Remove Ember skills for this repo
      guard let context = delegate.modelContext else {
        return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Model context not available"))
      }
      
      DefaultSkillsService.removeEmberSkills(context: context, repoPath: repoPath)
      return (200, makeResult(id: id, result: [
        "removed": true,
        "repoPath": repoPath
      ]))
      
    default:
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Invalid action: \(action). Use 'check', 'seed', 'update', or 'remove'"))
    }
  }
  
  func handleSkillsInit(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let repoPath = arguments["repoPath"] as? String else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing required parameter: repoPath"))
    }
    let force = arguments["force"] as? Bool ?? false

    let peelDir = URL(fileURLWithPath: repoPath).appendingPathComponent(".peel")
    let directivesURL = peelDir.appendingPathComponent("directives.md")
    let skillsURL = peelDir.appendingPathComponent("skills.json")

    var created: [String] = []
    var skipped: [String] = []

    do {
      try FileManager.default.createDirectory(at: peelDir, withIntermediateDirectories: true)

      if force || !FileManager.default.fileExists(atPath: directivesURL.path) {
        let directivesContent = LocalChatToolsHandler.emberDirectiveRules
        try directivesContent.write(to: directivesURL, atomically: true, encoding: .utf8)
        created.append("directives.md")
      } else {
        skipped.append("directives.md")
      }

      if force || !FileManager.default.fileExists(atPath: skillsURL.path) {
        guard let bundleURL = Bundle.main.url(forResource: "EmberSkillsBundle", withExtension: "json"),
              let bundleData = try? Data(contentsOf: bundleURL) else {
          return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "EmberSkillsBundle.json not found in app bundle"))
        }
        try bundleData.write(to: skillsURL)
        created.append("skills.json")
      } else {
        skipped.append("skills.json")
      }
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Failed to initialize .peel directory: \(error.localizedDescription)"))
    }

    var summary = "Initialized .peel/ in \(repoPath)"
    if !created.isEmpty { summary += "\nCreated: \(created.joined(separator: ", "))" }
    if !skipped.isEmpty { summary += "\nSkipped (already exist): \(skipped.joined(separator: ", "))" }

    return (200, makeResult(id: id, result: ["summary": summary, "created": created, "skipped": skipped]))
  }

}
