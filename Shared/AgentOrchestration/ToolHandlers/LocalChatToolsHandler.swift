//
//  LocalChatToolsHandler.swift
//  Peel
//
//  MCP tool handler for local chat via MLX models.
//  Provides chat.send, chat.status, and chat.unload tools for testing
//  and programmatic access to the local LLM chat service.
//
//  Created on 2/24/26.
//

#if os(macOS)
import Foundation
import MCPCore

// MARK: - Local Chat Tools Handler

final class LocalChatToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?

  /// The chat service instance — lazily created on first use
  private var chatService: MLXChatService?
  private var currentTier: MLXEditorModelTier = .auto

  let supportedTools: Set<String> = [
    "chat.send",
    "chat.status",
    "chat.unload",
  ]

  init() {}

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "chat.send":
      return await handleSend(id: id, arguments: arguments)
    case "chat.status":
      return handleStatus(id: id)
    case "chat.unload":
      return await handleUnload(id: id)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool: \(name)"))
    }
  }

  // MARK: - chat.send

  private func handleSend(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard case .success(let message) = requireString("message", from: arguments, id: id) else {
      return missingParamError(id: id, param: "message")
    }

    let tierString = optionalString("tier", from: arguments, default: "auto") ?? "auto"
    let requestedTier = parseTier(tierString)

    // If tier changed or no service, create a new one
    if chatService == nil || requestedTier != currentTier {
      if let old = chatService {
        print("[MCP Chat] Unloading previous model (tier was \(currentTier), now \(requestedTier))")
        await old.unload()
      }
      currentTier = requestedTier
      chatService = MLXChatService(tier: requestedTier)
      print("[MCP Chat] Created service with tier: \(requestedTier)")
    }

    guard let service = chatService else {
      return internalError(id: id, message: "Failed to create chat service")
    }

    // Log what we're about to load
    print("[MCP Chat] Service model name: \(service.modelName), tier: \(service.tier)")

    do {
      let stream = try await service.sendMessage(message)

      var fullResponse = ""
      var tokenCount = 0
      let startTime = Date()

      for await chunk in stream {
        fullResponse += chunk
        tokenCount += 1
      }

      let elapsed = Date().timeIntervalSince(startTime)
      let tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0

      return (200, makeResult(id: id, result: [
        "response": fullResponse,
        "model": service.modelName,
        "tier": service.tier.rawValue,
        "tokens": tokenCount,
        "tokensPerSecond": round(tokensPerSecond * 10) / 10,
        "elapsedSeconds": round(elapsed * 10) / 10,
        "historyLength": await service.getHistoryCount(),
      ]))
    } catch {
      return internalError(id: id, message: "Chat error: \(error.localizedDescription)")
    }
  }

  // MARK: - chat.status

  private func handleStatus(id: Any?) -> (Int, Data) {
    let memGB = getMemoryGB()
    let recommendedTier = MLXEditorModelTier.recommended(forMemoryGB: memGB)
    let recommendedConfig = MLXEditorModelConfig.recommendedModel()

    var result: [String: Any] = [
      "machineRamGB": Int(memGB),
      "recommendedTier": recommendedTier.rawValue,
      "recommendedModel": recommendedConfig.name,
      "recommendedHuggingFaceId": recommendedConfig.huggingFaceId,
      "currentTier": currentTier.rawValue,
      "isLoaded": chatService != nil,
      "availableModels": MLXEditorModelConfig.availableModels.map { model in
        [
          "name": model.name,
          "tier": model.tier.rawValue,
          "huggingFaceId": model.huggingFaceId,
          "contextLength": model.contextLength,
        ] as [String: Any]
      },
    ]

    if let service = chatService {
      result["loadedModel"] = service.modelName
      result["loadedTier"] = service.tier.rawValue
    }

    return (200, makeResult(id: id, result: result))
  }

  // MARK: - chat.unload

  private func handleUnload(id: Any?) async -> (Int, Data) {
    if let service = chatService {
      await service.unload()
      chatService = nil
      return (200, makeResult(id: id, result: [
        "message": "Chat model unloaded — memory freed",
        "wasLoaded": true,
      ]))
    } else {
      return (200, makeResult(id: id, result: [
        "message": "No chat model was loaded",
        "wasLoaded": false,
      ]))
    }
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "chat.send",
        description: "Send a message to the local MLX chat model and get a response. The model is loaded lazily on first call (~45GB download for xlarge tier). macOS only.",
        inputSchema: [
          "type": "object",
          "properties": [
            "message": ["type": "string", "description": "The message to send to the chat model"],
            "tier": ["type": "string", "description": "Model tier: auto, small, medium, large, xlarge (default: auto)"],
          ],
          "required": ["message"],
        ],
        category: .codeEdit,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chat.status",
        description: "Get the status of the local chat service including loaded model, recommended tier for this machine, and available models.",
        inputSchema: [
          "type": "object",
          "properties": [:],
        ],
        category: .codeEdit,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chat.unload",
        description: "Unload the local chat model to free RAM. The model will be reloaded on next chat.send call.",
        inputSchema: [
          "type": "object",
          "properties": [:],
        ],
        category: .codeEdit,
        isMutating: true
      ),
    ]
  }

  // MARK: - Helpers

  private func parseTier(_ string: String) -> MLXEditorModelTier {
    switch string {
    case "small": return .small
    case "medium": return .medium
    case "large": return .large
    case "xlarge": return .xlarge
    default: return .auto
    }
  }

  private func getMemoryGB() -> Double {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return Double(size) / 1_073_741_824.0
  }
}

#endif
