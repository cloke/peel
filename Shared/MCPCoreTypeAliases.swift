//
//  MCPCoreTypeAliases.swift
//  Peel
//
//  Type aliases to bridge MCPCore types with existing app types.
//  This provides a gradual migration path - existing code continues
//  to work while we move toward using MCPCore types directly.
//
//  Created for issue #22 - MCP automation framework package
//

import Foundation
import MCPCore

// MARK: - JSON-RPC Type Aliases
// These can be used directly from MCPCore

// MARK: - Tool Definition Type Aliases
// Note: The app currently defines these nested in MCPServerService.
// These aliases allow gradual migration to MCPCore types.

/// Alias for MCPCore tool category
public typealias MCPToolCategoryCore = MCPCore.MCPToolCategory

/// Alias for MCPCore tool group
public typealias MCPToolGroupCore = MCPCore.MCPToolGroup

/// Alias for MCPCore tool definition
public typealias MCPToolDefinitionCore = MCPCore.MCPToolDefinition

// MARK: - Agent Type Aliases

/// Alias for MCPCore agent role
public typealias MCPAgentRoleCore = MCPCore.MCPAgentRole

/// Alias for MCPCore agent type
public typealias MCPAgentTypeCore = MCPCore.MCPAgentType

/// Alias for MCPCore agent state
public typealias MCPAgentStateCore = MCPCore.MCPAgentState

/// Alias for MCPCore framework hint
public typealias MCPFrameworkHintCore = MCPCore.MCPFrameworkHint

/// Alias for MCPCore copilot model
public typealias MCPCopilotModelCore = MCPCore.MCPCopilotModel

// MARK: - Chain Template Type Aliases

/// Alias for MCPCore chain template
public typealias MCPChainTemplateCore = MCPCore.MCPChainTemplate

/// Alias for MCPCore agent step template
public typealias MCPAgentStepTemplateCore = MCPCore.MCPAgentStepTemplate

// MARK: - DTO Type Aliases

/// Alias for MCPCore run record DTO
public typealias MCPRunRecordDTO = MCPCore.MCPRunRecordDTO

/// Alias for MCPCore run result DTO
public typealias MCPRunResultDTO = MCPCore.MCPRunResultDTO

/// Alias for MCPCore chain run status
public typealias MCPChainRunStatus = MCPCore.MCPChainRunStatus

/// Alias for MCPCore server status
public typealias MCPServerStatusCore = MCPCore.MCPServerStatus

// MARK: - Protocol Aliases

/// Alias for MCPCore data persisting protocol
public typealias MCPDataPersistingProtocol = MCPCore.MCPDataPersisting

// MARK: - JSON-RPC Aliases (for direct use)

public typealias JSONRPCRequest = MCPCore.JSONRPCRequest
public typealias JSONRPCResponse = MCPCore.JSONRPCResponse
public typealias JSONRPCError = MCPCore.JSONRPCError
public typealias JSONRPCId = MCPCore.JSONRPCId
public typealias JSONRPCParams = MCPCore.JSONRPCParams
public typealias AnyCodable = MCPCore.AnyCodable
