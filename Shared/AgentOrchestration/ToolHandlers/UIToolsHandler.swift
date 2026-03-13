//
//  UIToolsHandler.swift
//  KitchenSync
//
//  Created as part of #158: Extract UI tools from MCPServerService.
//

import Foundation
import MCPCore

// MARK: - UI Tools Handler

/// Handles UI automation tools: ui.tap, ui.setText, ui.toggle, ui.select, ui.navigate, ui.back, ui.snapshot
@MainActor
public final class UIToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  public let supportedTools: Set<String> = [
    "ui.tap",
    "ui.setText",
    "ui.toggle",
    "ui.select",
    "ui.navigate",
    "ui.back",
    "ui.snapshot"
  ]

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "ui.tap":
      return await handleTap(id: id, arguments: arguments)
    case "ui.setText":
      return handleSetText(id: id, arguments: arguments)
    case "ui.toggle":
      return handleToggle(id: id, arguments: arguments)
    case "ui.select":
      return handleSelect(id: id, arguments: arguments)
    case "ui.navigate":
      return handleNavigate(id: id, arguments: arguments)
    case "ui.back":
      return handleBack(id: id)
    case "ui.snapshot":
      return handleSnapshot(id: id)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }

  // MARK: - ui.navigate

  private func handleNavigate(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let delegate else { return notConfiguredError(id: id) }

    guard case .success(let viewId) = requireString("viewId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "viewId")
    }

    // Also accept repo:<key> for direct repo navigation
    if viewId.hasPrefix("repo:") {
      let repoKey = String(viewId.dropFirst(5))
      delegate.recordUIActionRequested("ui.navigate:\(viewId)")
      UserDefaults.standard.set(repoKey, forKey: "repositories.selectedRepoKey")
      delegate.navigateToSidebar("repositories")
      delegate.recordUIActionHandled("ui.navigate:\(viewId)")
      return (200, makeResult(id: id, result: ["viewId": viewId, "status": "navigated"]))
    }

    guard delegate.availableViewIds().contains(viewId) else {
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.unknownViewId, message: "Unknown viewId '\(viewId)'. Available: \(delegate.availableViewIds().joined(separator: ", "))"))
    }

    delegate.recordUIActionRequested("ui.navigate:\(viewId)")
    delegate.navigateToSidebar(viewId)
    delegate.recordUIActionHandled("ui.navigate:\(viewId)")
    return (200, makeResult(id: id, result: ["viewId": viewId, "status": "navigated"]))
  }

  // MARK: - ui.tap

  private func handleTap(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let delegate else { return notConfiguredError(id: id) }

    guard case .success(let controlId) = requireString("controlId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "controlId")
    }

    let currentViewId = delegate.currentToolId()
    let availableControls = delegate.availableToolControlIds() + delegate.availableControlIds(for: currentViewId)
    guard availableControls.contains(controlId) else {
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.unknownControlId, message: "Unknown controlId"))
    }

    delegate.recordUIActionRequested(controlId)
    if controlId.hasPrefix("tool.") {
      let toolId = controlId.replacingOccurrences(of: "tool.", with: "")
      delegate.setCurrentToolId(toolId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "status": "tapped"]))
    }

    if controlId.hasPrefix("agents.") {
      UserDefaults.standard.set(controlId, forKey: "agents.selectedInfrastructure")
    }

    if controlId.hasPrefix("repositories.overview.sync.") || controlId.hasPrefix("repositories.rag.sync.") {
      if let service = delegate as? MCPServerService {
        let result = await service.handleRepositoryAutomationTap(controlId: controlId)
        delegate.recordUIActionHandled(controlId)
        return (200, makeResult(id: id, result: result))
      }

      NotificationCenter.default.post(
        name: Notification.Name("RepositoryAutomationActionRequested"),
        object: controlId
      )
    }

    delegate.lastUIAction = UIAction(controlId: controlId)
    return (200, makeResult(id: id, result: ["controlId": controlId, "status": "queued"]))
  }

  // MARK: - ui.setText

  private func handleSetText(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let delegate else { return notConfiguredError(id: id) }

    guard case .success(let controlId) = requireString("controlId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "controlId")
    }
    let value = arguments["value"] as? String ?? ""

    switch controlId {
    case "repositories.search":
      UserDefaults.standard.set(value, forKey: "repositories.searchText")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))
    case "brew.search":
      UserDefaults.standard.set(value, forKey: "brew.searchText")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))
    case "agents.localRag.repoPath":
      delegate.localRagRepoPath = value
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))
    case "agents.localRag.query":
      delegate.localRagQuery = value
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))
    default:
      break
    }
    return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.setTextNotSupported, message: "setText not supported"))
  }

  // MARK: - ui.toggle

  private func handleToggle(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let delegate else { return notConfiguredError(id: id) }

    guard case .success(let controlId) = requireString("controlId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "controlId")
    }
    let value = arguments["on"] as? Bool

    switch controlId {
    case "github.showArchived":
      let current = UserDefaults.standard.bool(forKey: "github-show-archived")
      let next = value ?? !current
      UserDefaults.standard.set(next, forKey: "github-show-archived")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": next]))
    default:
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.toggleNotSupported, message: "toggle not supported"))
    }
  }

  // MARK: - ui.select

  private func handleSelect(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard let delegate else { return notConfiguredError(id: id) }

    guard case .success(let controlId) = requireString("controlId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "controlId")
    }
    let value = optionalString("value", from: arguments) ?? ""

    switch controlId {
    case "repositories.selectRepo":
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return invalidParamError(id: id, param: "value", reason: "Repository value cannot be empty")
      }

      let resolvedRepoKey = resolveRepositorySelectionKey(trimmed)
      guard !resolvedRepoKey.isEmpty else {
        return invalidParamError(id: id, param: "value", reason: "Unknown repository")
      }

      UserDefaults.standard.set(resolvedRepoKey, forKey: "repositories.selectedRepoKey")
      NotificationCenter.default.post(
        name: Notification.Name("RepositoryAutomationRepoSelected"),
        object: resolvedRepoKey
      )
      UserDefaults.standard.set("repositories", forKey: "current-tool")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": resolvedRepoKey]))

    case "repositories.selectTab":
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard ["overview", "branches", "activity", "rag", "skills"].contains(normalized) else {
        return invalidParamError(id: id, param: "value", reason: "Must be overview/branches/activity/rag/skills")
      }

      UserDefaults.standard.set(normalized, forKey: "repositories.selectedTab")
      NotificationCenter.default.post(
        name: Notification.Name("RepositoryAutomationTabSelected"),
        object: normalized
      )
      UserDefaults.standard.set("repositories", forKey: "current-tool")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": normalized]))

    case "repositories.selectScope":
      let normalized = value.lowercased()
      guard ["local", "remote"].contains(normalized) else {
        return invalidParamError(id: id, param: "value", reason: "Must be local/remote")
      }
      UserDefaults.standard.set(normalized, forKey: "repositories.selectedScope")
      UserDefaults.standard.set("repositories", forKey: "current-tool")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": normalized]))

    case "brew.source":
      guard value == "Installed" || value == "Available" else {
        return invalidParamError(id: id, param: "value", reason: "Must be 'Installed' or 'Available'")
      }
      UserDefaults.standard.set(value, forKey: "brew.source")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "agents.localRag.mode":
      let normalized = value.lowercased()
      guard let mode = MCPServerService.RAGSearchMode(rawValue: normalized) else {
        return invalidParamError(id: id, param: "value", reason: "Invalid RAG mode")
      }
      delegate.localRagSearchMode = mode
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": mode.rawValue]))

    case "agents.localRag.limit":
      guard let parsed = Int(value), (1...25).contains(parsed) else {
        return invalidParamError(id: id, param: "value", reason: "Must be 1-25")
      }
      delegate.localRagSearchLimit = parsed
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": parsed]))

    case "workspaces.selectWorkspace":
      UserDefaults.standard.set(value, forKey: "workspaces.selectedWorkspaceName")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "workspaces.selectRepo":
      UserDefaults.standard.set(value, forKey: "workspaces.selectedRepoName")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "workspaces.selectWorktree":
      UserDefaults.standard.set(value, forKey: "workspaces.selectedWorktreePath")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "workspaces.selectWorktreeName":
      let nameMap = delegate.worktreeNameMapFromDefaults()
      guard let path = nameMap[value], !path.isEmpty else {
        return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Unknown worktree name"))
      }
      UserDefaults.standard.set(value, forKey: "workspaces.selectedWorktreeName")
      UserDefaults.standard.set(path, forKey: "workspaces.selectedWorktreePath")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value, "path": path]))

    case "git.selectRepo":
      UserDefaults.standard.set(value, forKey: "git.selectedRepoPath")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "git.selectSidebarItem":
      UserDefaults.standard.set(value, forKey: "git.selectedSidebarItem")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "git.selectStatusPath":
      UserDefaults.standard.set(value, forKey: "git.selectedStatusPath")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "git.selectBranch", "repositories.git.selectBranch":
      UserDefaults.standard.set(value, forKey: "git.selectedBranchName")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "git.selectCommit", "repositories.git.selectCommit":
      UserDefaults.standard.set(value, forKey: "git.selectedCommitSha")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "github.selectFavorite":
      UserDefaults.standard.set(value, forKey: "github.automationSelectedFavoriteKey")
      UserDefaults.standard.set("", forKey: "github.automationSelectedRecentPRKey")
      // Backward compatibility with legacy keys
      UserDefaults.standard.set(value, forKey: "github.selectedFavoriteKey")
      UserDefaults.standard.set("", forKey: "github.selectedRecentPRKey")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "github.selectRecentPR":
      UserDefaults.standard.set(value, forKey: "github.automationSelectedRecentPRKey")
      UserDefaults.standard.set("", forKey: "github.automationSelectedFavoriteKey")
      // Backward compatibility with legacy keys
      UserDefaults.standard.set(value, forKey: "github.selectedRecentPRKey")
      UserDefaults.standard.set("", forKey: "github.selectedFavoriteKey")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "activity.filterMode":
      let normalized = value.lowercased()
      guard ["all", "running", "completed", "failed"].contains(normalized) else {
        return invalidParamError(id: id, param: "value", reason: "Must be all/running/completed/failed")
      }
      UserDefaults.standard.set(normalized, forKey: "activity.automationFilterMode")
      UserDefaults.standard.set("activity", forKey: "current-tool")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": normalized]))

    case "activity.filterRepo":
      UserDefaults.standard.set(value, forKey: "activity.automationFilterRepo")
      UserDefaults.standard.set("activity", forKey: "current-tool")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "activity.selectChain":
      UserDefaults.standard.set(value, forKey: "activity.automationSelectedChain")
      UserDefaults.standard.set("activity", forKey: "current-tool")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "activity.expandExecution":
      UserDefaults.standard.set(value, forKey: "activity.automationExpandExecution")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    default:
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.selectNotSupported, message: "select not supported"))
    }
  }

  // MARK: - ui.back

  private func handleBack(id: Any?) -> (Int, Data) {
    guard let delegate else { return notConfiguredError(id: id) }

    guard let current = delegate.currentToolId() else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.backNotSupported, message: "Back not supported"))
    }

    let viewIds = delegate.availableViewIds()
    guard let index = viewIds.firstIndex(of: current), index > 0 else {
      return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.backNotSupported, message: "Back not supported"))
    }
    let previous = viewIds[index - 1]
    delegate.setCurrentToolId(previous)
    return (200, makeResult(id: id, result: ["viewId": previous, "status": "navigated"]))
  }

  // MARK: - ui.snapshot

  private func handleSnapshot(id: Any?) -> (Int, Data) {
    guard let delegate else { return notConfiguredError(id: id) }

    let currentViewId = delegate.currentToolId()
    let controls = delegate.availableToolControlIds() + delegate.availableControlIds(for: currentViewId)
    let controlValues = delegate.controlValues(for: currentViewId)
    let snapshot: [String: Any] = [
      "currentViewId": currentViewId as Any,
      "availableViewIds": delegate.availableViewIds(),
      "controls": controls,
      "controlValues": controlValues
    ]
    return (200, makeResult(id: id, result: snapshot))
  }

  private func resolveRepositorySelectionKey(_ value: String) -> String {
    let defaults = UserDefaults.standard
    let availableKeys = defaults.stringArray(forKey: "repositories.availableRepoKeys") ?? []
    if availableKeys.contains(value) {
      return value
    }

    guard let data = defaults.data(forKey: "repositories.repoKeyByName"),
          let nameMap = try? JSONDecoder().decode([String: String].self, from: data) else {
      return ""
    }

    if let exact = nameMap[value] {
      return exact
    }

    let lowercase = value.lowercased()
    if let matched = nameMap.first(where: { $0.key.lowercased() == lowercase }) {
      return matched.value
    }

    return ""
  }
}

// MARK: - Tool Definitions

extension UIToolsHandler {
  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "ui.tap",
        description: "Tap a control by controlId",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"]
          ],
          "required": ["controlId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "ui.setText",
        description: "Set text for a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "value": ["type": "string"]
          ],
          "required": ["controlId", "value"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "ui.toggle",
        description: "Toggle a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "on": ["type": "boolean"]
          ],
          "required": ["controlId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "ui.select",
        description: "Select a value for a control",
        inputSchema: [
          "type": "object",
          "properties": [
            "controlId": ["type": "string"],
            "value": ["type": "string"]
          ],
          "required": ["controlId", "value"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "ui.navigate",
        description: "Navigate to a top-level view by viewId",
        inputSchema: [
          "type": "object",
          "properties": [
            "viewId": ["type": "string"]
          ],
          "required": ["viewId"]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "ui.back",
        description: "Navigate back to the previous view (if supported)",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: true,
        requiresForeground: true
      ),
      MCPToolDefinition(
        name: "ui.snapshot",
        description: "Return the current view and visible control IDs",
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: false,
        requiresForeground: true
      ),
    ]
  }
}
