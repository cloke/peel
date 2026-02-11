//
//  CodeEditToolsHandler.swift
//  Peel
//
//  MCP tool handler for local code editing via MLX models.
//  Uses Qwen3-Coder-Next (80B MoE) on machines with sufficient RAM.
//
//  Created on 2/10/26.
//

#if os(macOS)
import Foundation
import MCPCore

// MARK: - Code Edit Tools Handler Delegate

/// Extended delegate for code-edit-specific functionality
@MainActor
protocol CodeEditToolsHandlerDelegate: MCPToolHandlerDelegate {
  /// Search RAG for related code (for style context)
  func searchRagForTool(query: String, mode: MCPServerService.RAGSearchMode, repoPath: String?, limit: Int, matchAll: Bool, modulePath: String?) async throws -> [RAGToolSearchResult]
}

// MARK: - Code Edit Tools Handler

final class CodeEditToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?

  /// Typed delegate for code-edit operations
  private var codeEditDelegate: CodeEditToolsHandlerDelegate? {
    delegate as? CodeEditToolsHandlerDelegate
  }

  /// Lazily-created editor instance (heavy — loads model on first use)
  private var editor: MLXCodeEditor?

  let supportedTools: Set<String> = [
    "code.edit",
    "code.edit.status",
    "code.edit.unload",
  ]

  init() {}

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "code.edit":
      return await handleEdit(id: id, arguments: arguments)
    case "code.edit.status":
      return await handleStatus(id: id)
    case "code.edit.unload":
      return await handleUnload(id: id)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool: \(name)"))
    }
  }

  // MARK: - code.edit

  private func handleEdit(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    // Validate required params
    guard case .success(let filePath) = requireString("filePath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "filePath")
    }
    guard case .success(let instruction) = requireString("instruction", from: arguments, id: id) else {
      return missingParamError(id: id, param: "instruction")
    }

    // Optional params
    let modeString = optionalString("mode", from: arguments, default: "diff") ?? "diff"
    let mode: MLXEditMode
    switch modeString {
    case "fullFile": mode = .fullFile
    case "snippet": mode = .snippet
    default: mode = .diff
    }

    let additionalContext = optionalString("context", from: arguments)
    let useRag = optionalBool("useRag", from: arguments, default: true)
    let tierString = optionalString("tier", from: arguments, default: "auto") ?? "auto"

    // Check feasibility
    guard MLXCodeEditorFactory.isEditingFeasible() else {
      return (400, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Local code editing requires at least 24GB RAM. This machine has insufficient memory. Consider delegating to a swarm peer."
      ))
    }

    // Read the source file
    let sourceCode: String
    do {
      sourceCode = try String(contentsOfFile: filePath, encoding: .utf8)
    } catch {
      return (400, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Cannot read file: \(error.localizedDescription)"
      ))
    }

    // Detect language from file extension
    let language = detectLanguage(from: filePath)

    // Optionally fetch related code from RAG for style matching
    var relatedContext = additionalContext
    if useRag, let codeEditDelegate {
      do {
        let ragResults = try await codeEditDelegate.searchRagForTool(
          query: instruction,
          mode: .vector,
          repoPath: nil, // Could derive from filePath
          limit: 3,
          matchAll: false,
          modulePath: nil
        )
        if !ragResults.isEmpty {
          let ragSnippets = ragResults.map { result in
            "// From: \(result.filePath) (lines \(result.startLine)-\(result.endLine))\n\(result.snippet)"
          }.joined(separator: "\n\n")
          relatedContext = [relatedContext, ragSnippets].compactMap { $0 }.joined(separator: "\n\n")
        }
      } catch {
        // RAG is best-effort — continue without it
        print("[CodeEdit] RAG context fetch failed: \(error.localizedDescription)")
      }
    }

    // Create or reuse editor
    let editor = await getOrCreateEditor(tierString: tierString)

    // Build request
    let request = MLXEditRequest(
      sourceCode: sourceCode,
      instruction: instruction,
      language: language,
      filePath: filePath,
      relatedContext: relatedContext,
      mode: mode
    )

    // Execute edit
    do {
      let result = try await editor.edit(request)

      return (200, makeResult(id: id, result: [
        "editedContent": result.editedContent,
        "explanation": result.explanation,
        "model": result.model,
        "durationMs": result.durationMs,
        "tokensGenerated": result.tokensGenerated,
        "mode": modeString,
        "filePath": filePath,
      ]))
    } catch {
      return (500, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.internalError,
        message: "Edit failed: \(error.localizedDescription)"
      ))
    }
  }

  // MARK: - code.edit.status

  private func handleStatus(id: Any?) async -> (Int, Data) {
    let recommendation = MLXCodeEditorFactory.recommendedTierDescription()
    let feasible = MLXCodeEditorFactory.isEditingFeasible()

    if let editor {
      let status = await editor.status()
      return (200, makeResult(id: id, result: [
        "available": true,
        "feasibleOnDevice": feasible,
        "modelName": status.modelName,
        "tier": status.tier.rawValue,
        "isLoaded": status.isLoaded,
        "huggingFaceId": status.huggingFaceId,
        "maxTokens": status.maxTokens,
        "contextLength": status.contextLength,
        "recommendation": recommendation,
      ]))
    } else {
      return (200, makeResult(id: id, result: [
        "available": true,
        "feasibleOnDevice": feasible,
        "isLoaded": false,
        "recommendation": recommendation,
        "note": "Editor model will be loaded on first code.edit call",
      ]))
    }
  }

  // MARK: - code.edit.unload

  private func handleUnload(id: Any?) async -> (Int, Data) {
    if let editor {
      await editor.unload()
      self.editor = nil
      return (200, makeResult(id: id, result: [
        "message": "Editor model unloaded — memory freed",
        "wasLoaded": true,
      ]))
    } else {
      return (200, makeResult(id: id, result: [
        "message": "No editor model was loaded",
        "wasLoaded": false,
      ]))
    }
  }

  // MARK: - Helpers

  private func getOrCreateEditor(tierString: String) async -> MLXCodeEditor {
    if let editor { return editor }

    let tier: MLXEditorModelTier
    switch tierString {
    case "small": tier = .small
    case "medium": tier = .medium
    case "large": tier = .large
    default: tier = .auto
    }

    let newEditor: MLXCodeEditor
    if tier == .auto {
      newEditor = MLXCodeEditor()
    } else {
      newEditor = MLXCodeEditor(tier: tier)
    }
    self.editor = newEditor
    return newEditor
  }

  private func detectLanguage(from filePath: String) -> String? {
    let ext = (filePath as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "py": return "python"
    case "js": return "javascript"
    case "ts": return "typescript"
    case "tsx": return "typescriptreact"
    case "jsx": return "javascriptreact"
    case "rb": return "ruby"
    case "rs": return "rust"
    case "go": return "go"
    case "java": return "java"
    case "kt": return "kotlin"
    case "c", "h": return "c"
    case "cpp", "cc", "cxx", "hpp": return "cpp"
    case "m": return "objective-c"
    case "mm": return "objective-cpp"
    case "sh", "bash", "zsh": return "shell"
    case "md": return "markdown"
    case "json": return "json"
    case "yaml", "yml": return "yaml"
    case "toml": return "toml"
    case "html": return "html"
    case "css": return "css"
    case "sql": return "sql"
    default: return nil
    }
  }
}

#endif
