//
//  MCPCoreTypeAliases.swift
//  Peel
//
//  Central import point for MCPCore types.
//  
//  Primary type aliases are defined in their respective files:
//  - Agent.swift: CopilotModel, AgentRole, AgentType, FrameworkHint
//  - MCPServerService.swift: ToolCategory, ToolGroup, ToolDefinition
//
//  This file provides additional aliases for direct MCPCore type access.
//
//  Created for issue #22 - MCP automation framework package
//

import Foundation
import MCPCore

// MARK: - DTO Type Aliases

/// Run record for serialization
public typealias MCPRunRecordDTO = MCPCore.MCPRunRecordDTO

/// Run result for serialization
public typealias MCPRunResultDTO = MCPCore.MCPRunResultDTO

/// Chain run status enum
public typealias MCPChainRunStatus = MCPCore.MCPChainRunStatus

/// Server status struct
public typealias MCPServerStatusCore = MCPCore.MCPServerStatus

// MARK: - Protocol Aliases

/// Data persistence protocol
public typealias MCPDataPersistingProtocol = MCPCore.MCPDataPersisting

// MARK: - JSON-RPC Aliases

public typealias JSONRPCRequest = MCPCore.JSONRPCRequest
public typealias JSONRPCResponse = MCPCore.JSONRPCResponse
public typealias JSONRPCError = MCPCore.JSONRPCError
public typealias JSONRPCId = MCPCore.JSONRPCId
public typealias JSONRPCParams = MCPCore.JSONRPCParams
public typealias AnyCodable = MCPCore.AnyCodable

// MARK: - MCPCore Type Access
// For files that need direct access to MCPCore types without their own import

/// Direct access to MCPCore chain template (portable version without validationConfig)
public typealias MCPChainTemplateCore = MCPCore.MCPChainTemplate

/// Direct access to MCPCore agent step template
public typealias MCPAgentStepTemplateCore = MCPCore.MCPAgentStepTemplate
