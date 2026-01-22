//
//  MCPUIAutomationProvider.swift
//  Peel
//
//  Created on 1/22/26.
//

import Foundation
import Observation

#if os(macOS)
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
    ["agents", "workspaces", "brew", "git", "github"]
  }

  public func viewTitle(for viewId: String) -> String {
    switch viewId {
    case "agents": return "Agents"
    case "workspaces": return "Workspaces"
    case "brew": return "Homebrew"
    case "git": return "Git"
    case "github": return "GitHub"
    default: return viewId.capitalized
    }
  }

  public func availableToolControlIds() -> [String] {
    availableViewIds().map { "tool.\($0)" }
  }

  public func availableControlIds(for viewId: String?) -> [String] {
    switch viewId {
    case "agents":
      return [
        "agents.newAgent",
        "agents.newChain",
        "agents.mcpDashboard",
        "agents.cliSetup",
        "agents.sessionSummary",
        "agents.vmIsolation",
        "agents.translationValidation",
        "agents.localRag",
        "agents.piiScrubber",
        "agents.localRag.refresh",
        "agents.localRag.repoPath",
        "agents.localRag.init",
        "agents.localRag.index",
        "agents.localRag.query",
        "agents.localRag.mode",
        "agents.localRag.limit",
        "agents.localRag.search",
        "agents.localRag.useCoreML"
      ]
    case "github":
      return [
        "github.login",
        "github.refresh",
        "github.showArchived",
        "github.logout",
        "github.selectFavorite",
        "github.selectRecentPR"
      ]
    case "brew":
      return ["brew.source", "brew.search"]
    case "workspaces":
      return [
        "workspaces.refresh",
        "workspaces.addWorkspace",
        "workspaces.createWorktree",
        "workspaces.openInVSCode",
        "workspaces.selectWorkspace",
        "workspaces.selectRepo",
        "workspaces.selectWorktree",
        "workspaces.selectWorktreeName",
        "workspaces.openSelectedWorktree",
        "workspaces.removeSelectedWorktree"
      ]
    case "git":
      return ["git.openRepository", "git.cloneRepository", "git.openInVSCode", "git.selectRepo"]
    default:
      return []
    }
  }

  public func controlValues(for viewId: String?) -> [String: Any] {
    switch viewId {
    case "github":
      let favoriteKeys = UserDefaults.standard.stringArray(forKey: "github.availableFavoriteKeys") ?? []
      let recentPRKeys = UserDefaults.standard.stringArray(forKey: "github.availableRecentPRKeys") ?? []
      return [
        "github.selectFavorite": favoriteKeys,
        "github.selectRecentPR": recentPRKeys
      ]
    case "brew":
      return [
        "brew.source": ["Installed", "Available"]
      ]
    case "workspaces":
      let workspaceNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableNames") ?? []
      let repoNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableRepoNames") ?? []
      let worktreePaths = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreePaths") ?? []
      let worktreeNames = UserDefaults.standard.stringArray(forKey: "workspaces.availableWorktreeNames") ?? []
      return [
        "workspaces.selectWorkspace": workspaceNames,
        "workspaces.selectRepo": repoNames,
        "workspaces.selectWorktree": worktreePaths,
        "workspaces.selectWorktreeName": worktreeNames
      ]
    case "agents":
      let limits = (1...25).map { String($0) }
      return [
        "agents.localRag.mode": ["text", "vector"],
        "agents.localRag.limit": limits
      ]
    case "git":
      let repoPaths = UserDefaults.standard.stringArray(forKey: "git.availableRepoPaths") ?? []
      let repoNames = UserDefaults.standard.stringArray(forKey: "git.availableRepoNames") ?? []
      return [
        "git.selectRepo": repoPaths,
        "git.selectRepoNames": repoNames
      ]
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
#else
@MainActor
public protocol MCPUIAutomationProviding: AnyObject { }

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
@Observable
public final class MCPUIAutomationStore: MCPUIAutomationProviding {
  public init() {}
  public var uiControlDocs: [ViewControlDoc] { [] }
  public var recentUIActions: [UIActionRecord] { [] }
  public var lastUIAction: UIAction? = nil
  public var lastUIActionHandled: String? = nil
  public var lastUIActionHandledAt: Date? = nil

  public func availableViewIds() -> [String] { [] }
  public func viewTitle(for viewId: String) -> String { viewId }
  public func availableToolControlIds() -> [String] { [] }
  public func availableControlIds(for viewId: String?) -> [String] { [] }
  public func controlValues(for viewId: String?) -> [String: Any] { [:] }
  public func currentToolId() -> String? { nil }
  public func setCurrentToolId(_ toolId: String) { }
  public func worktreeNameMapFromDefaults() -> [String: String] { [:] }
  public func recordUIActionHandled(_ controlId: String) { }
  public func recordUIActionRequested(_ controlId: String) { }
  public func recordUIActionForegroundNeeded(_ controlId: String) { }
}
#endif
