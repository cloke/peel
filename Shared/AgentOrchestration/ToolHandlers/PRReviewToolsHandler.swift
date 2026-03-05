//
//  PRReviewToolsHandler.swift
//  Peel
//
//  MCP tool handler for PR review queue operations.
//  Allows agents to list, enqueue, fix, push, and manage PR reviews.
//

import Foundation
import MCPCore

@MainActor
final class PRReviewToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?

  /// Reference to the shared PR review queue.
  var prReviewQueue: PRReviewQueue?

  let supportedTools: Set<String> = [
    "pr.review.queue.list",
    "pr.review.queue.enqueue",
    "pr.review.queue.status",
    "pr.review.queue.update",
    "pr.review.queue.remove",
  ]

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let queue = prReviewQueue else {
      return internalError(id: id, message: "PR review queue not initialized")
    }

    switch name {
    case "pr.review.queue.list":
      return handleList(id: id, arguments: arguments, queue: queue)
    case "pr.review.queue.enqueue":
      return handleEnqueue(id: id, arguments: arguments, queue: queue)
    case "pr.review.queue.status":
      return handleStatus(id: id, arguments: arguments, queue: queue)
    case "pr.review.queue.update":
      return handleUpdate(id: id, arguments: arguments, queue: queue)
    case "pr.review.queue.remove":
      return handleRemove(id: id, arguments: arguments, queue: queue)
    default:
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown PR review tool: \(name)"
      ))
    }
  }

  // MARK: - pr.review.queue.list

  private func handleList(id: Any?, arguments: [String: Any], queue: PRReviewQueue) -> (Int, Data) {
    let filter = arguments["filter"] as? String // "active", "completed", or nil for all
    let items: [[String: Any]]
    switch filter {
    case "active":
      items = queue.activeItems.map { itemDict($0) }
    case "completed":
      items = queue.completedItems.map { itemDict($0) }
    default:
      items = queue.summary()
    }

    return (200, makeResult(id: id, result: [
      "items": items,
      "count": items.count,
    ]))
  }

  // MARK: - pr.review.queue.enqueue

  private func handleEnqueue(id: Any?, arguments: [String: Any], queue: PRReviewQueue) -> (Int, Data) {
    guard case .success(let owner) = requireString("repoOwner", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoOwner")
    }
    guard case .success(let repo) = requireString("repoName", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoName")
    }
    guard let prNumber = arguments["prNumber"] as? Int else {
      return missingParamError(id: id, param: "prNumber")
    }
    let prTitle = (arguments["prTitle"] as? String) ?? "PR #\(prNumber)"
    let headRef = (arguments["headRef"] as? String) ?? ""
    let htmlURL = (arguments["htmlURL"] as? String) ?? ""

    let item = queue.enqueue(
      repoOwner: owner,
      repoName: repo,
      prNumber: prNumber,
      prTitle: prTitle,
      headRef: headRef,
      htmlURL: htmlURL
    )

    return (200, makeResult(id: id, result: [
      "id": item.id.uuidString,
      "phase": item.phase,
      "message": "PR #\(prNumber) enqueued for review",
    ]))
  }

  // MARK: - pr.review.queue.status

  private func handleStatus(id: Any?, arguments: [String: Any], queue: PRReviewQueue) -> (Int, Data) {
    guard let item = resolveItem(arguments: arguments, queue: queue) else {
      return notFoundError(id: id, what: "Queue item")
    }
    return (200, makeResult(id: id, result: itemDict(item)))
  }

  // MARK: - pr.review.queue.update

  private func handleUpdate(id: Any?, arguments: [String: Any], queue: PRReviewQueue) -> (Int, Data) {
    guard let item = resolveItem(arguments: arguments, queue: queue) else {
      return notFoundError(id: id, what: "Queue item")
    }
    guard case .success(let phase) = requireString("phase", from: arguments, id: id) else {
      return missingParamError(id: id, param: "phase")
    }

    switch phase {
    case PRReviewPhase.reviewing:
      let chainId = (arguments["chainId"] as? String) ?? ""
      let worktreePath = (arguments["worktreePath"] as? String) ?? ""
      let model = (arguments["model"] as? String) ?? ""
      queue.markReviewing(item, chainId: chainId, worktreePath: worktreePath, model: model)

    case PRReviewPhase.reviewed:
      let output = (arguments["output"] as? String) ?? ""
      let verdict = (arguments["verdict"] as? String) ?? ""
      queue.markReviewed(item, output: output, verdict: verdict)

    case PRReviewPhase.needsFix:
      queue.markNeedsFix(item)

    case PRReviewPhase.fixing:
      let chainId = (arguments["chainId"] as? String) ?? ""
      let model = (arguments["model"] as? String) ?? ""
      queue.markFixing(item, chainId: chainId, model: model)

    case PRReviewPhase.fixed:
      queue.markFixed(item)

    case PRReviewPhase.readyToPush:
      queue.markReadyToPush(item)

    case PRReviewPhase.pushing:
      queue.markPushing(item)

    case PRReviewPhase.pushed:
      let result = (arguments["result"] as? String) ?? ""
      queue.markPushed(item, result: result)

    case PRReviewPhase.failed:
      let error = (arguments["error"] as? String) ?? "Unknown error"
      queue.markFailed(item, error: error)

    default:
      return invalidParamError(id: id, param: "phase", reason: "Unknown phase: \(phase)")
    }

    return (200, makeResult(id: id, result: [
      "id": item.id.uuidString,
      "phase": item.phase,
      "message": "Updated to \(PRReviewPhase.displayName[phase] ?? phase)",
    ]))
  }

  // MARK: - pr.review.queue.remove

  private func handleRemove(id: Any?, arguments: [String: Any], queue: PRReviewQueue) -> (Int, Data) {
    guard let item = resolveItem(arguments: arguments, queue: queue) else {
      return notFoundError(id: id, what: "Queue item")
    }
    let prNumber = item.prNumber
    queue.remove(item)
    return (200, makeResult(id: id, result: [
      "message": "Removed PR #\(prNumber) from queue",
    ]))
  }

  // MARK: - Helpers

  /// Resolve a queue item from arguments (by id, or by repo+prNumber).
  private func resolveItem(arguments: [String: Any], queue: PRReviewQueue) -> PRReviewQueueItem? {
    if let idStr = arguments["id"] as? String, let uuid = UUID(uuidString: idStr) {
      return queue.find(id: uuid)
    }
    if let owner = arguments["repoOwner"] as? String,
       let repo = arguments["repoName"] as? String,
       let prNumber = arguments["prNumber"] as? Int {
      return queue.find(repoOwner: owner, repoName: repo, prNumber: prNumber)
    }
    return nil
  }

  /// Build a dictionary representation of a queue item for MCP responses.
  private func itemDict(_ item: PRReviewQueueItem) -> [String: Any] {
    var dict: [String: Any] = [
      "id": item.id.uuidString,
      "repo": "\(item.repoOwner)/\(item.repoName)",
      "prNumber": item.prNumber,
      "prTitle": item.prTitle,
      "phase": item.phase,
      "phaseDisplay": PRReviewPhase.displayName[item.phase] ?? item.phase,
      "headRef": item.headRef,
      "createdAt": ISO8601DateFormatter().string(from: item.createdAt),
      "lastUpdatedAt": ISO8601DateFormatter().string(from: item.lastUpdatedAt),
    ]
    if !item.reviewVerdict.isEmpty { dict["reviewVerdict"] = item.reviewVerdict }
    if !item.reviewChainId.isEmpty { dict["reviewChainId"] = item.reviewChainId }
    if !item.fixChainId.isEmpty { dict["fixChainId"] = item.fixChainId }
    if !item.worktreePath.isEmpty { dict["worktreePath"] = item.worktreePath }
    if !item.pushResult.isEmpty { dict["pushResult"] = item.pushResult }
    if let error = item.lastError { dict["lastError"] = error }
    if !item.reviewOutput.isEmpty {
      dict["reviewOutputPreview"] = String(item.reviewOutput.prefix(500))
    }
    return dict
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "pr.review.queue.list",
        description: "List PR review queue items. Returns all items or filter by 'active' or 'completed'.",
        inputSchema: [
          "type": "object",
          "properties": [
            "filter": [
              "type": "string",
              "enum": ["active", "completed"],
              "description": "Filter items: 'active' (in-progress), 'completed' (pushed/approved), or omit for all",
            ]
          ],
        ],
        category: .github,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "pr.review.queue.enqueue",
        description: "Add a PR to the review queue. If already queued, returns the existing item.",
        inputSchema: [
          "type": "object",
          "properties": [
            "repoOwner": ["type": "string", "description": "Repository owner"],
            "repoName": ["type": "string", "description": "Repository name"],
            "prNumber": ["type": "integer", "description": "PR number"],
            "prTitle": ["type": "string", "description": "PR title"],
            "headRef": ["type": "string", "description": "PR head branch ref"],
            "htmlURL": ["type": "string", "description": "PR URL"],
          ],
          "required": ["repoOwner", "repoName", "prNumber"],
        ],
        category: .github,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "pr.review.queue.status",
        description: "Get the status of a specific PR review queue item. Identify by 'id' or by 'repoOwner'+'repoName'+'prNumber'.",
        inputSchema: [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Queue item UUID"],
            "repoOwner": ["type": "string", "description": "Repository owner"],
            "repoName": ["type": "string", "description": "Repository name"],
            "prNumber": ["type": "integer", "description": "PR number"],
          ],
        ],
        category: .github,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "pr.review.queue.update",
        description: """
          Update the phase of a PR review queue item. Valid phases: \
          pending, reviewing, reviewed, needsFix, fixing, fixed, \
          readyToPush, pushing, pushed, approved, failed. \
          Some phases accept additional arguments (chainId, output, verdict, error, etc).
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Queue item UUID"],
            "repoOwner": ["type": "string", "description": "Repository owner"],
            "repoName": ["type": "string", "description": "Repository name"],
            "prNumber": ["type": "integer", "description": "PR number"],
            "phase": ["type": "string", "description": "Target phase"],
            "chainId": ["type": "string", "description": "Chain run ID (for reviewing/fixing)"],
            "worktreePath": ["type": "string", "description": "Worktree path (for reviewing)"],
            "model": ["type": "string", "description": "Model used (for reviewing/fixing)"],
            "output": ["type": "string", "description": "Review output text (for reviewed)"],
            "verdict": ["type": "string", "description": "Review verdict (for reviewed)"],
            "result": ["type": "string", "description": "Push result (for pushed)"],
            "error": ["type": "string", "description": "Error message (for failed)"],
          ],
          "required": ["phase"],
        ],
        category: .github,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "pr.review.queue.remove",
        description: "Remove a PR from the review queue. Identify by 'id' or by 'repoOwner'+'repoName'+'prNumber'.",
        inputSchema: [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Queue item UUID"],
            "repoOwner": ["type": "string", "description": "Repository owner"],
            "repoName": ["type": "string", "description": "Repository name"],
            "prNumber": ["type": "integer", "description": "PR number"],
          ],
        ],
        category: .github,
        isMutating: true
      ),
    ]
  }
}
