//
//  MCPServerService+SmallDelegates.swift
//  KitchenSync
//
//  Extracted from MCPServerService.swift for maintainability.
//  Contains small delegate conformances that don't warrant their own files.
//

import Foundation

// MARK: - MCPToolHandlerDelegate Conformance

extension MCPServerService: MCPToolHandlerDelegate {
  public func availableViewIds() -> [String] {
    uiAutomationProvider.availableViewIds()
  }

  public func availableToolControlIds() -> [String] {
    uiAutomationProvider.availableToolControlIds()
  }

  public func availableControlIds(for viewId: String?) -> [String] {
    uiAutomationProvider.availableControlIds(for: viewId)
  }

  public func controlValues(for viewId: String?) -> [String: Any] {
    uiAutomationProvider.controlValues(for: viewId)
  }

  public func currentToolId() -> String? {
    uiAutomationProvider.currentToolId()
  }

  public func setCurrentToolId(_ viewId: String) {
    uiAutomationProvider.setCurrentToolId(viewId)
  }

  public func worktreeNameMapFromDefaults() -> [String: String] {
    uiAutomationProvider.worktreeNameMapFromDefaults()
  }
}

// MARK: - ParallelToolsHandlerDelegate

extension MCPServerService: ParallelToolsHandlerDelegate {
  // Note: parallelWorktreeRunner is already exposed with internal visibility.
  // Private properties need explicit accessors for protocol conformance.
  var parallelDataService: DataService? {
    dataService
  }

  var parallelTelemetryProvider: MCPTelemetryProviding {
    telemetryProvider
  }
}

// MARK: - RepoToolsHandlerDelegate

extension MCPServerService: RepoToolsHandlerDelegate {
  var repoDataService: DataService? {
    dataService
  }
}

// MARK: - CodeEditToolsHandlerDelegate

#if os(macOS)
extension MCPServerService: CodeEditToolsHandlerDelegate {}
#endif
