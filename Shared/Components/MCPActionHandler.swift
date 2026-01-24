//
//  MCPActionHandler.swift
//  Peel
//
//  Created on 1/24/26.
//

import SwiftUI

/// A mapping from an MCP control ID to an action to perform.
public struct MCPActionMapping: Identifiable {
  public let id: String
  public let controlId: String
  public let action: () -> Void
  
  public init(_ controlId: String, action: @escaping () -> Void) {
    self.id = controlId
    self.controlId = controlId
    self.action = action
  }
}

/// View modifier that handles MCP UI actions declaratively.
///
/// Usage:
/// ```swift
/// .mcpActions(mcpServer) {
///   MCPActionMapping("git.openRepository") { addRepository() }
///   MCPActionMapping("git.cloneRepository") { isCloning = true }
/// }
/// ```
struct MCPActionHandlerModifier: ViewModifier {
  let mcpServer: MCPServerService
  let mappings: [MCPActionMapping]
  
  func body(content: Content) -> some View {
    content
      .onChange(of: mcpServer.lastUIAction?.id) {
        guard let uiAction = mcpServer.lastUIAction else { return }
        
        if let mapping = mappings.first(where: { $0.controlId == uiAction.controlId }) {
          mapping.action()
          mcpServer.recordUIActionHandled(uiAction.controlId)
        }
        
        mcpServer.lastUIAction = nil
      }
  }
}

/// Result builder for creating arrays of MCPActionMapping
@resultBuilder
public struct MCPActionMappingBuilder {
  public static func buildBlock(_ components: MCPActionMapping...) -> [MCPActionMapping] {
    components
  }
  
  public static func buildOptional(_ component: [MCPActionMapping]?) -> [MCPActionMapping] {
    component ?? []
  }
  
  public static func buildEither(first component: [MCPActionMapping]) -> [MCPActionMapping] {
    component
  }
  
  public static func buildEither(second component: [MCPActionMapping]) -> [MCPActionMapping] {
    component
  }
  
  public static func buildArray(_ components: [[MCPActionMapping]]) -> [MCPActionMapping] {
    components.flatMap { $0 }
  }
}

extension View {
  /// Adds MCP action handling with a declarative mapping.
  ///
  /// Example:
  /// ```swift
  /// .mcpActions(mcpServer) {
  ///   MCPActionMapping("agents.newAgent") { showingNewAgentSheet = true }
  ///   MCPActionMapping("agents.newChain") { showingNewChainSheet = true }
  /// }
  /// ```
  public func mcpActions(
    _ mcpServer: MCPServerService,
    @MCPActionMappingBuilder mappings: () -> [MCPActionMapping]
  ) -> some View {
    modifier(MCPActionHandlerModifier(mcpServer: mcpServer, mappings: mappings()))
  }
  
  /// Adds MCP action handling with an array of mappings.
  public func mcpActions(_ mcpServer: MCPServerService, _ mappings: [MCPActionMapping]) -> some View {
    modifier(MCPActionHandlerModifier(mcpServer: mcpServer, mappings: mappings))
  }
}

// MARK: - Convenience for async actions

extension MCPActionMapping {
  /// Creates a mapping that runs an async action on the main actor.
  @MainActor
  public static func async(_ controlId: String, action: @MainActor @escaping () async -> Void) -> MCPActionMapping {
    MCPActionMapping(controlId) {
      Task { @MainActor in
        await action()
      }
    }
  }
}

#if DEBUG
struct MCPActionHandler_Previews: PreviewProvider {
  static var previews: some View {
    Text("MCP Action Handler")
  }
}
#endif
