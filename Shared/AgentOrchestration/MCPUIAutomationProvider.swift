//
//  MCPUIAutomationProvider.swift
//  Peel
//
//  Created on 1/22/26.
//

import Foundation
import Observation
public struct ControlDoc: Identifiable {
  public let controlId: String
  public let values: [String]

  public var id: String { controlId }

  public init(controlId: String, values: [String]) {
    self.controlId = controlId
    self.values = values
  }
}

public struct ViewControlDoc: Identifiable {
  public let viewId: String
  public let title: String
  public let controls: [ControlDoc]

  public var id: String { viewId }

  public init(viewId: String, title: String, controls: [ControlDoc]) {
    self.viewId = viewId
    self.title = title
    self.controls = controls
  }
}

public struct UIAction: Identifiable {
  public let id: UUID
  public let controlId: String

  public init(controlId: String) {
    self.id = UUID()
    self.controlId = controlId
  }
}

public struct UIActionRecord: Identifiable {
  public let id: UUID
  public let controlId: String
  public let status: String
  public let timestamp: Date

  public init(controlId: String, status: String, timestamp: Date = Date()) {
    self.id = UUID()
    self.controlId = controlId
    self.status = status
    self.timestamp = timestamp
  }
}

@MainActor
public protocol MCPUIAutomationProviding: AnyObject {
  var uiControlDocs: [ViewControlDoc] { get }
  var recentUIActions: [UIActionRecord] { get }
  var lastUIAction: UIAction? { get set }
  var lastUIActionHandled: String? { get }
  var lastUIActionHandledAt: Date? { get }

  func availableViewIds() -> [String]
  func viewTitle(for viewId: String) -> String
  func availableToolControlIds() -> [String]
  func availableControlIds(for viewId: String?) -> [String]
  func controlValues(for viewId: String?) -> [String: Any]
  func currentToolId() -> String?
  func setCurrentToolId(_ toolId: String)
  func worktreeNameMapFromDefaults() -> [String: String]
  func recordUIActionHandled(_ controlId: String)
  func recordUIActionRequested(_ controlId: String)
  func recordUIActionForegroundNeeded(_ controlId: String)
}

@MainActor
@Observable
public final class MCPUIAutomationStore: MCPUIAutomationProviding {
  public private(set) var recentUIActions: [UIActionRecord] = []
  public private(set) var lastUIActionHandled: String?
  public private(set) var lastUIActionHandledAt: Date?
  public var lastUIAction: UIAction?

  public init() {}

  public var uiControlDocs: [ViewControlDoc] {
    var docs = availableViewIds().map { viewId -> ViewControlDoc in
      let controls = availableControlIds(for: viewId)
      let values = controlValues(for: viewId)
      let controlDocs = controls.map { controlId in
        ControlDoc(controlId: controlId, values: stringValues(values[controlId]))
      }
      return ViewControlDoc(viewId: viewId, title: viewTitle(for: viewId), controls: controlDocs)
    }

    let toolControls = availableToolControlIds().map { controlId in
      ControlDoc(controlId: controlId, values: [])
    }
    if !toolControls.isEmpty {
      docs.insert(
        ViewControlDoc(viewId: "tool-shortcuts", title: "Tool Shortcuts", controls: toolControls),
        at: 0
      )
    }

    return docs
  }

  public func recordUIActionHandled(_ controlId: String) {
    lastUIActionHandled = controlId
    lastUIActionHandledAt = Date()
    appendUIActionRecord(controlId: controlId, status: "handled")
  }

  public func recordUIActionRequested(_ controlId: String) {
    appendUIActionRecord(controlId: controlId, status: "requested")
  }

  public func recordUIActionForegroundNeeded(_ controlId: String) {
    appendUIActionRecord(controlId: controlId, status: "foreground-needed")
  }

  public func availableViewIds() -> [String] {
    ["repositories", "activity"]
  }

  public func viewTitle(for viewId: String) -> String {
    switch viewId {
    case "repositories": return "Repositories"
    case "activity": return "Activity"
    // Legacy view IDs — map to new equivalents
    case "agents", "workspaces", "swarm": return "Activity"
    case "brew": return "Homebrew"
    case "git", "github": return "Repositories"
    default: return viewId.capitalized
    }
  }

  public func availableToolControlIds() -> [String] {
    availableViewIds().map { "tool.\($0)" }
  }

  public func availableControlIds(for viewId: String?) -> [String] {
    switch viewId {
    case "repositories":
      return [
        "repositories.search",
        "repositories.add",
        "repositories.refresh",
        "repositories.selectRepo",
        "repositories.selectTab",
        "repositories.overview.sync.pullNow",
        // Git controls (available when repo is cloned)
        "repositories.git.openRepository",
        "repositories.git.selectBranch",
        "repositories.git.selectCommit",
        // RAG controls
        "repositories.rag.index",
        "repositories.rag.search",
        "repositories.rag.analyze",
        "repositories.rag.enrich",
        "repositories.rag.sync.push",
        "repositories.rag.sync.pull",
        "repositories.rag.sync.pullWan"
      ]
    case "activity":
      return [
        "activity.filterMode",
        "activity.filterRepo",
        "activity.runTask",
        "activity.selectChain",
        "activity.startSwarm",
        // Legacy agent controls (kept for backward compat)
        "activity.agents.newChain",
        "activity.rag.refresh",
        "activity.rag.repoPath",
        "activity.rag.index",
        "activity.rag.search"
      ]
    // Legacy view IDs — return mapped controls
    case "agents":
      return availableControlIds(for: "activity")
    case "git", "github":
      return availableControlIds(for: "repositories")
    default:
      return []
    }
  }

  public func controlValues(for viewId: String?) -> [String: Any] {
    switch viewId {
    case "repositories":
      let repoKeys = UserDefaults.standard.stringArray(forKey: "repositories.availableRepoKeys") ?? []
      let repoNames = UserDefaults.standard.stringArray(forKey: "repositories.availableRepoNames") ?? []
      let selectedRepoKey = UserDefaults.standard.string(forKey: "repositories.selectedRepoKey") ?? ""
      let selectedRepoName = UserDefaults.standard.string(forKey: "repositories.selectedRepoName") ?? ""
      let selectedTab = UserDefaults.standard.string(forKey: "repositories.selectedTab") ?? "overview"
      let overviewSyncStatus = UserDefaults.standard.string(forKey: "repositories.overview.sync.status") ?? ""
      let overviewSyncSource = UserDefaults.standard.string(forKey: "repositories.overview.sync.source") ?? ""
      let ragSyncStatus = UserDefaults.standard.string(forKey: "repositories.rag.sync.status") ?? ""
      let ragSyncPeers = UserDefaults.standard.stringArray(forKey: "repositories.rag.sync.peers") ?? []
      let ragSyncWANWorkers = UserDefaults.standard.stringArray(forKey: "repositories.rag.sync.wanWorkers") ?? []
      let branchNames = UserDefaults.standard.stringArray(forKey: "git.availableLocalBranchNames") ?? []
      let commitShas = UserDefaults.standard.stringArray(forKey: "git.availableCommitShas") ?? []
      return [
        "repositories.selectRepo": repoKeys,
        "repositories.availableRepoNames": repoNames,
        "repositories.selectedRepoKey": selectedRepoKey,
        "repositories.selectedRepoName": selectedRepoName,
        "repositories.selectTab": ["overview", "branches", "activity", "rag", "skills"],
        "repositories.selectedTab": selectedTab,
        "repositories.overview.sync.status": overviewSyncStatus,
        "repositories.overview.sync.source": overviewSyncSource,
        "repositories.rag.sync.status": ragSyncStatus,
        "repositories.rag.sync.peers": ragSyncPeers,
        "repositories.rag.sync.wanWorkers": ragSyncWANWorkers,
        "repositories.git.selectBranch": branchNames,
        "repositories.git.selectCommit": commitShas
      ]
    case "activity":
      let limits = (1...25).map { String($0) }
      return [
        "activity.filterMode": ["all", "running", "completed", "failed"],
        "activity.rag.search.mode": ["text", "vector"],
        "activity.rag.search.limit": limits
      ]
    // Legacy view IDs — return mapped values
    case "agents":
      return controlValues(for: "activity")
    case "git", "github":
      return controlValues(for: "repositories")
    default:
      return [:]
    }
  }

  public func currentToolId() -> String? {
    UserDefaults.standard.string(forKey: "current-tool")
  }

  public func setCurrentToolId(_ toolId: String) {
    UserDefaults.standard.set(toolId, forKey: "current-tool")
  }

  public func worktreeNameMapFromDefaults() -> [String: String] {
    guard let data = UserDefaults.standard.data(forKey: "workspaces.availableWorktreeNameMap"),
          let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
      return [:]
    }
    return decoded
  }

  private func appendUIActionRecord(controlId: String, status: String) {
    let record = UIActionRecord(controlId: controlId, status: status)
    recentUIActions.insert(record, at: 0)
    if recentUIActions.count > 25 {
      recentUIActions.removeLast(recentUIActions.count - 25)
    }
  }

  private func stringValues(_ value: Any?) -> [String] {
    if let strings = value as? [String] {
      return strings
    }
    return []
  }
}
