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
      return handleTap(id: id, arguments: arguments)
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

    guard delegate.availableViewIds().contains(viewId) else {
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.unknownViewId, message: "Unknown viewId"))
    }

    delegate.recordUIActionRequested("ui.navigate:\(viewId)")
    delegate.setCurrentToolId(viewId)
    delegate.recordUIActionHandled("ui.navigate:\(viewId)")
    return (200, makeResult(id: id, result: ["viewId": viewId, "status": "navigated"]))
  }

  // MARK: - ui.tap

  private func handleTap(id: Any?, arguments: [String: Any]) -> (Int, Data) {
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
    case "agents.localRag.useCoreML":
      let current = UserDefaults.standard.bool(forKey: "localrag.useCoreML")
      let next = value ?? !current
      delegate.localRagUseCoreML = next
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

    case "git.selectBranch":
      UserDefaults.standard.set(value, forKey: "git.selectedBranchName")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "git.selectCommit":
      UserDefaults.standard.set(value, forKey: "git.selectedCommitSha")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "github.selectFavorite":
      UserDefaults.standard.set(value, forKey: "github.selectedFavoriteKey")
      UserDefaults.standard.set("", forKey: "github.selectedRecentPRKey")
      delegate.recordUIActionRequested(controlId)
      delegate.recordUIActionHandled(controlId)
      return (200, makeResult(id: id, result: ["controlId": controlId, "value": value]))

    case "github.selectRecentPR":
      UserDefaults.standard.set(value, forKey: "github.selectedRecentPRKey")
      UserDefaults.standard.set("", forKey: "github.selectedFavoriteKey")
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
}
