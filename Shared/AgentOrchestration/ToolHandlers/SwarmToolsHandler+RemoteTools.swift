//
//  SwarmToolsHandler+RemoteTools.swift
//  Peel
//
//  Handlers for Remote MCP Tool Proxy (#376) and Agent Personalities (#383).
//  Security: default-deny authorization, rate limiting, audit logging.
//

import Foundation
import MCPCore
import SwiftData

// MARK: - Remote Tool Call Handlers

extension SwarmToolsHandler {

  /// Execute an MCP tool on a remote connected peer via WebRTC.
  func handleRemoteToolCall(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard coordinator.isActive else {
      return serviceNotActiveError(id: id, service: "Swarm")
    }

    guard let toolName = arguments["toolName"] as? String else {
      return missingParamError(id: id, param: "toolName")
    }

    let toolArguments = arguments["arguments"] as? [String: Any] ?? [:]
    let agentRole = arguments["agentRole"] as? String
    let timeoutSeconds = min(arguments["timeout"] as? Int ?? 30, 300)

    // Resolve target worker
    let workerId: String
    if let explicitId = arguments["workerId"] as? String {
      workerId = explicitId
    } else if let workerName = arguments["workerName"] as? String {
      let lowered = workerName.lowercased()
      if let worker = coordinator.connectedWorkers.first(where: {
        $0.name.lowercased().contains(lowered) ||
        $0.displayName.lowercased().contains(lowered)
      }) {
        workerId = worker.id
      } else {
        return (400, makeError(id: id, code: -32602, message: "No connected worker matching name '\(workerName)'"))
      }
    } else if let firstWorker = coordinator.connectedWorkers.first {
      workerId = firstWorker.id
    } else {
      return (400, makeError(id: id, code: -32602, message: "No connected workers available"))
    }

    let workerName = coordinator.connectedWorkers.first(where: { $0.id == workerId })?.displayName ?? workerId

    do {
      let result = try await coordinator.sendRemoteToolCallAndWait(
        toolName: toolName,
        arguments: toolArguments,
        to: workerId,
        agentRole: agentRole,
        timeout: .seconds(timeoutSeconds)
      )

      var response: [String: Any] = [
        "requestId": result.requestId.uuidString,
        "success": result.success,
        "durationMs": result.durationMs,
        "workerId": workerId,
        "workerName": workerName,
        "toolName": toolName,
      ]

      if let resultJSON = result.resultJSON {
        // Parse the JSON-RPC response to extract just the result content
        if let data = resultJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          response["toolResult"] = parsed["result"]
          if let error = parsed["error"] {
            response["toolError"] = error
          }
        } else {
          response["rawResult"] = resultJSON
        }
      }

      if let errorMessage = result.errorMessage {
        response["errorMessage"] = errorMessage
      }

      return (200, makeResult(id: id, result: response))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Remote tool call failed: \(error.localizedDescription)"))
    }
  }

  /// View the audit log of remote tool calls.
  func handleRemoteToolAudit(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let limit = arguments["limit"] as? Int ?? 50
    let filterPeerId = arguments["peerId"] as? String
    let filterToolName = arguments["toolName"] as? String

    var entries = coordinator.remoteToolCallAuditLog

    if let peerId = filterPeerId {
      entries = entries.filter { $0.callerPeerId == peerId || $0.targetPeerId == peerId }
    }
    if let toolName = filterToolName {
      entries = entries.filter { $0.toolName == toolName }
    }

    let limited = Array(entries.prefix(limit))
    let formatted = limited.map { entry -> [String: Any] in
      var dict: [String: Any] = [
        "requestId": entry.requestId.uuidString,
        "callerPeerId": entry.callerPeerId,
        "targetPeerId": entry.targetPeerId,
        "toolName": entry.toolName,
        "success": entry.success,
        "durationMs": entry.durationMs,
        "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
      ]
      if let role = entry.callerAgentRole { dict["callerAgentRole"] = role }
      if let error = entry.errorMessage { dict["errorMessage"] = error }
      return dict
    }

    let result: [String: Any] = [
      "totalEntries": coordinator.remoteToolCallAuditLog.count,
      "returned": formatted.count,
      "entries": formatted,
    ]
    return (200, makeResult(id: id, result: result))
  }

  /// Manage remote tool access policies.
  func handleRemoteToolPolicy(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let action = arguments["action"] as? String else {
      return missingParamError(id: id, param: "action")
    }

    guard let context = coordinator.modelContext else {
      return (500, makeError(id: id, code: -32000, message: "Model context not available"))
    }

    switch action {
    case "list":
      let descriptor = FetchDescriptor<RemoteToolPolicy>()
      guard let policies = try? context.fetch(descriptor) else {
        return (200, makeResult(id: id, result: ["policies": [] as [Any]]))
      }
      let formatted = policies.map { policy -> [String: Any] in
        [
          "id": policy.id.uuidString,
          "peerDeviceId": policy.peerDeviceId,
          "peerDisplayName": policy.peerDisplayName,
          "allowedTools": policy.allowedTools,
          "allowSensitiveTools": policy.allowSensitiveTools,
          "maxRequestsPerMinute": policy.maxRequestsPerMinute,
          "isActive": policy.isActive,
        ]
      }
      return (200, makeResult(id: id, result: ["policies": formatted]))

    case "get":
      guard let peerId = arguments["peerId"] as? String else {
        return missingParamError(id: id, param: "peerId")
      }
      let peerDeviceId = peerId
      let descriptor = FetchDescriptor<RemoteToolPolicy>(
        predicate: #Predicate { $0.peerDeviceId == peerDeviceId }
      )
      guard let policies = try? context.fetch(descriptor), let policy = policies.first else {
        return (200, makeResult(id: id, result: ["found": false, "message": "No policy exists for peer \(peerId). Default: deny all."]))
      }
      let dict: [String: Any] = [
        "found": true,
        "id": policy.id.uuidString,
        "peerDeviceId": policy.peerDeviceId,
        "peerDisplayName": policy.peerDisplayName,
        "allowedTools": policy.allowedTools,
        "allowSensitiveTools": policy.allowSensitiveTools,
        "maxRequestsPerMinute": policy.maxRequestsPerMinute,
        "isActive": policy.isActive,
      ]
      return (200, makeResult(id: id, result: dict))

    case "set":
      guard let peerId = arguments["peerId"] as? String else {
        return missingParamError(id: id, param: "peerId")
      }
      let peerDeviceId = peerId
      let descriptor = FetchDescriptor<RemoteToolPolicy>(
        predicate: #Predicate { $0.peerDeviceId == peerDeviceId }
      )
      let existing = try? context.fetch(descriptor)
      let policy = existing?.first ?? RemoteToolPolicy(peerDeviceId: peerId)

      if let name = arguments["peerName"] as? String { policy.peerDisplayName = name }
      if let tools = arguments["allowedTools"] as? String { policy.allowedTools = tools }
      if let sensitive = arguments["allowSensitiveTools"] as? Bool { policy.allowSensitiveTools = sensitive }
      if let rate = arguments["maxRequestsPerMinute"] as? Int { policy.maxRequestsPerMinute = rate }
      if let active = arguments["isActive"] as? Bool { policy.isActive = active }
      policy.updatedAt = Date()

      if existing?.first == nil {
        context.insert(policy)
      }

      do {
        try context.save()
        return (200, makeResult(id: id, result: [
          "success": true,
          "peerDeviceId": peerId,
          "allowedTools": policy.allowedTools,
          "allowSensitiveTools": policy.allowSensitiveTools,
          "maxRequestsPerMinute": policy.maxRequestsPerMinute,
          "isActive": policy.isActive,
        ]))
      } catch {
        return (500, makeError(id: id, code: -32000, message: "Failed to save policy: \(error)"))
      }

    default:
      return (400, makeError(id: id, code: -32602, message: "Unknown action '\(action)'. Use: list, get, set"))
    }
  }
}

// MARK: - Agent Personality Handlers

extension SwarmToolsHandler {

  /// List all available agent personalities.
  func handleAgentPersonalities(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let filterRole = arguments["role"] as? String
    let activeOnly = arguments["activeOnly"] as? Bool ?? true

    guard let context = coordinator.modelContext else {
      return (500, makeError(id: id, code: -32000, message: "Model context not available"))
    }

    // Ensure built-in personalities exist
    await ensureBuiltInPersonalities(context: context)

    let descriptor = FetchDescriptor<AgentPersonality>()
    guard let all = try? context.fetch(descriptor) else {
      return (200, makeResult(id: id, result: ["personalities": [] as [Any]]))
    }

    var personalities = all
    if activeOnly { personalities = personalities.filter(\.isActive) }
    if let role = filterRole { personalities = personalities.filter { $0.role == role } }

    let formatted = personalities.map { p -> [String: Any] in
      var dict: [String: Any] = [
        "slug": p.slug,
        "name": p.name,
        "role": p.role,
        "expertiseTags": p.expertiseTags,
        "collaborationStyle": p.collaborationStyle,
        "isBuiltIn": p.isBuiltIn,
        "isActive": p.isActive,
        "preferredModelTier": p.preferredModelTier,
      ]
      if !p.allowedTools.isEmpty { dict["allowedTools"] = p.allowedTools }
      if !p.deniedTools.isEmpty { dict["deniedTools"] = p.deniedTools }
      return dict
    }

    return (200, makeResult(id: id, result: [
      "count": formatted.count,
      "personalities": formatted,
    ]))
  }

  /// Create a new custom agent personality.
  func handleAgentPersonalityCreate(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let slug = arguments["slug"] as? String else {
      return missingParamError(id: id, param: "slug")
    }
    guard let name = arguments["name"] as? String else {
      return missingParamError(id: id, param: "name")
    }
    guard let role = arguments["role"] as? String else {
      return missingParamError(id: id, param: "role")
    }
    guard let systemPrompt = arguments["systemPrompt"] as? String else {
      return missingParamError(id: id, param: "systemPrompt")
    }

    guard let context = coordinator.modelContext else {
      return (500, makeError(id: id, code: -32000, message: "Model context not available"))
    }

    // Check for duplicate slug
    let slugValue = slug
    let descriptor = FetchDescriptor<AgentPersonality>(
      predicate: #Predicate { $0.slug == slugValue }
    )
    if let existing = try? context.fetch(descriptor), !existing.isEmpty {
      return (400, makeError(id: id, code: -32602, message: "Personality with slug '\(slug)' already exists"))
    }

    let personality = AgentPersonality(
      slug: slug,
      name: name,
      role: role,
      systemPrompt: systemPrompt,
      expertiseTags: arguments["expertiseTags"] as? String ?? "",
      allowedTools: arguments["allowedTools"] as? String ?? "",
      deniedTools: arguments["deniedTools"] as? String ?? "",
      collaborationStyle: arguments["collaborationStyle"] as? String ?? "collaborative",
      isBuiltIn: false,
      preferredModelTier: arguments["preferredModelTier"] as? String ?? "standard"
    )

    context.insert(personality)
    do {
      try context.save()
      return (200, makeResult(id: id, result: [
        "success": true,
        "slug": slug,
        "name": name,
        "role": role,
        "collaborationStyle": personality.collaborationStyle,
        "preferredModelTier": personality.preferredModelTier,
      ]))
    } catch {
      return (500, makeError(id: id, code: -32000, message: "Failed to save personality: \(error)"))
    }
  }

  /// Ensure built-in personalities exist in the database.
  private func ensureBuiltInPersonalities(context: ModelContext) async {
    let builtIns = AgentPersonality.builtInPersonalities()
    for template in builtIns {
      let slugValue = template.slug
      let descriptor = FetchDescriptor<AgentPersonality>(
        predicate: #Predicate { $0.slug == slugValue }
      )
      if let existing = try? context.fetch(descriptor), !existing.isEmpty {
        continue  // Already exists
      }
      context.insert(template)
    }
    try? context.save()
  }
}
