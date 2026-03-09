import Foundation
import MCPCore

/// Handler for Xcode MCP tools
/// Exposes Xcode's code intelligence, diagnostics, and refactoring capabilities
/// to Peel agents via the MCP protocol
struct XcodeToolHandler: MCPToolHandler {
    let adapter: XcodeMCPAdapter
    
    static var supportedTools: [String] {
        [
            // Symbols & Code Intelligence
            "xcode.symbols.lookup",
            "xcode.symbols.references",
            "xcode.symbols.typeInfo",
            "xcode.symbols.documentation",
            "xcode.symbols.rename",
            "xcode.symbols.hierarchy",
            "xcode.symbols.conformances",
            "xcode.symbols.usage",
            "xcode.symbols.definitionLocation",
            "xcode.symbols.completion",
            "xcode.symbols.quickHelp",
            "xcode.symbols.breadcrumbs",
            "xcode.symbols.interfaces",
            "xcode.symbols.callGraph",
            
            // Diagnostics & Analysis
            "xcode.diagnostics.get",
            "xcode.diagnostics.forFile",
            "xcode.diagnostics.forRange",
            "xcode.diagnostics.concurrency",
            "xcode.diagnostics.memorySafety",
            "xcode.diagnostics.performance",
            "xcode.diagnostics.security",
            "xcode.diagnostics.accessibility",
            "xcode.diagnostics.localization",
            "xcode.diagnostics.api",
            "xcode.diagnostics.deprecated",
            "xcode.diagnostics.warnings",
            
            // Project Information
            "xcode.project.getInfo",
            "xcode.project.getTargets",
            "xcode.project.getSchemes",
            "xcode.project.getDependencies",
            "xcode.project.getFrameworks",
            "xcode.project.getFiles",
            "xcode.project.getFilesByType",
            "xcode.project.getBuildSettings",
            "xcode.project.getDeploymentTarget",
            "xcode.project.getConventions",
            "xcode.project.getLocalization",
            
            // Refactoring & Fixes
            "xcode.refactor.extractMethod",
            "xcode.refactor.extractVariable",
            "xcode.refactor.moveToFile",
            "xcode.refactor.autoFix",
            "xcode.refactor.formatCode",
            "xcode.refactor.modernizeSwift",
            "xcode.refactor.addImports",
            "xcode.refactor.changeSignature",
            "xcode.refactor.inlineFunction",
            "xcode.refactor.extractProtocol",
            
            // Build & Validation
            "xcode.build.validate",
            "xcode.build.compile",
            "xcode.build.getErrors",
            "xcode.build.getWarnings",
            "xcode.build.analyze",
            "xcode.test.run",
            "xcode.test.coverage",
            "xcode.test.getResults",
        ]
    }
    
    // MARK: - MCPToolHandler Implementation
    
    func handle(
        toolName: String,
        arguments: [String: Any]
    ) async throws -> MCPToolResult {
        // Route to appropriate handler based on tool category
        let parts = toolName.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: true)
        
        guard parts.count >= 3 else {
            throw XcodeToolError.invalidToolName(toolName)
        }
        
        let category = String(parts[1])
        
        switch category {
        case "symbols":
            return try await handleSymbolsTool(toolName: toolName, arguments: arguments)
        case "diagnostics":
            return try await handleDiagnosticsTool(toolName: toolName, arguments: arguments)
        case "project":
            return try await handleProjectTool(toolName: toolName, arguments: arguments)
        case "refactor":
            return try await handleRefactoringTool(toolName: toolName, arguments: arguments)
        case "build", "test":
            return try await handleBuildTool(toolName: toolName, arguments: arguments)
        default:
            throw XcodeToolError.unknownCategory(category)
        }
    }
    
    // MARK: - Symbol Tools
    
    private func handleSymbolsTool(
        toolName: String,
        arguments: [String: Any]
    ) async throws -> MCPToolResult {
        let operation = toolName.split(separator: ".").last.map(String.init) ?? ""
        
        switch operation {
        case "lookup":
            guard let symbol = arguments["symbol"] as? String else {
                throw XcodeToolError.missingParameter("symbol")
            }
            let file = arguments["file"] as? String
            
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: ["symbol": symbol, "file": file as Any]
            )
            return .success(result)
            
        case "references":
            guard let symbol = arguments["symbol"] as? String else {
                throw XcodeToolError.missingParameter("symbol")
            }
            
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: ["symbol": symbol]
            )
            return .success(result)
            
        case "rename":
            guard let oldName = arguments["oldName"] as? String,
                  let newName = arguments["newName"] as? String else {
                throw XcodeToolError.missingParameters(["oldName", "newName"])
            }
            
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: ["oldName": oldName, "newName": newName]
            )
            return .success(result)
            
        default:
            // Generic symbol tool pass-through
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: arguments
            )
            return .success(result)
        }
    }
    
    // MARK: - Diagnostics Tools
    
    private func handleDiagnosticsTool(
        toolName: String,
        arguments: [String: Any]
    ) async throws -> MCPToolResult {
        let operation = toolName.split(separator: ".").last.map(String.init) ?? ""
        
        switch operation {
        case "get":
            // Get all diagnostics, optionally filtered by file or category
            let file = arguments["file"] as? String
            let category = arguments["category"] as? String
            
            var params: [String: Any] = [:]
            if let file = file {
                params["file"] = file
            }
            if let category = category {
                params["category"] = category
            }
            
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: params
            )
            return .success(result)
            
        case "concurrency":
            // Get Swift 6 concurrency issues specifically
            let result = try await adapter.callTool(
                toolName: "xcode.diagnostics.concurrency",
                arguments: [:]
            )
            return .success(result)
            
        case "memorySafety":
            // Get memory safety issues
            let result = try await adapter.callTool(
                toolName: "xcode.diagnostics.memorySafety",
                arguments: [:]
            )
            return .success(result)
            
        default:
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: arguments
            )
            return .success(result)
        }
    }
    
    // MARK: - Project Tools
    
    private func handleProjectTool(
        toolName: String,
        arguments: [String: Any]
    ) async throws -> MCPToolResult {
        let operation = toolName.split(separator: ".").last.map(String.init) ?? ""
        
        switch operation {
        case "getInfo":
            // Get general project information
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: [:]
            )
            return .success(result)
            
        case "getConventions":
            // Get project coding conventions and patterns
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: [:]
            )
            return .success(result)
            
        default:
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: arguments
            )
            return .success(result)
        }
    }
    
    // MARK: - Refactoring Tools
    
    private func handleRefactoringTool(
        toolName: String,
        arguments: [String: Any]
    ) async throws -> MCPToolResult {
        let operation = toolName.split(separator: ".").last.map(String.init) ?? ""
        
        switch operation {
        case "autoFix":
            guard let issueId = arguments["issueId"] as? String else {
                throw XcodeToolError.missingParameter("issueId")
            }
            
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: ["issueId": issueId]
            )
            return .success(result)
            
        case "formatCode":
            guard let files = arguments["files"] as? [String] else {
                throw XcodeToolError.missingParameter("files")
            }
            
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: ["files": files]
            )
            return .success(result)
            
        default:
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: arguments
            )
            return .success(result)
        }
    }
    
    // MARK: - Build Tools
    
    private func handleBuildTool(
        toolName: String,
        arguments: [String: Any]
    ) async throws -> MCPToolResult {
        let operation = toolName.split(separator: ".").last.map(String.init) ?? ""
        
        switch operation {
        case "validate":
            // Validate that code will compile
            let files = arguments["files"] as? [String]
            
            var params: [String: Any] = [:]
            if let files = files {
                params["files"] = files
            }
            
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: params
            )
            return .success(result)
            
        default:
            let result = try await adapter.callTool(
                toolName: toolName,
                arguments: arguments
            )
            return .success(result)
        }
    }
}

// MARK: - Error Types

enum XcodeToolError: LocalizedError {
    case invalidToolName(String)
    case unknownCategory(String)
    case missingParameter(String)
    case missingParameters([String])
    case callFailed(String)
    case xcodeNotAvailable
    
    var errorDescription: String? {
        switch self {
        case .invalidToolName(let name):
            return "Invalid Xcode tool name: \(name)"
        case .unknownCategory(let category):
            return "Unknown tool category: \(category)"
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .missingParameters(let params):
            return "Missing required parameters: \(params.joined(separator: ", "))"
        case .callFailed(let reason):
            return "Xcode tool call failed: \(reason)"
        case .xcodeNotAvailable:
            return "Xcode is not available. Ensure Xcode 26.3+ is installed and running."
        }
    }
}
