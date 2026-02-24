//
//  MLXChatService.swift
//  Peel
//
//  Simple chat service wrapping MLX LLM models for interactive conversation.
//  Shares model tiers with MLXCodeEditor but uses a conversational system prompt.
//
//  Created on 2/10/26.
//

#if os(macOS)
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Chat Message

struct ChatMessage: Identifiable, Sendable {
  let id: UUID
  let role: Role
  let content: String
  let timestamp: Date

  enum Role: String, Sendable {
    case user
    case assistant
    case system
  }

  init(role: Role, content: String) {
    self.id = UUID()
    self.role = role
    self.content = content
    self.timestamp = Date()
  }
}

// MARK: - Chat Service Actor

/// Interactive chat service using local MLX LLM models.
/// Maintains conversation history and streams token-by-token responses.
actor MLXChatService {
  private var modelContainer: ModelContainer?
  private let config: MLXEditorModelConfig
  private var isLoaded = false
  private var conversationHistory: [Chat.Message] = []

  nonisolated let modelName: String
  nonisolated let tier: MLXEditorModelTier

  private let systemMessage = """
  You are a helpful coding assistant running locally on the user's Mac via MLX.
  You have expertise in Swift, SwiftUI, Python, Rust, and general software engineering.
  Keep responses concise and practical. Use code blocks with language tags when showing code.
  You can help with: code review, debugging, architecture advice, refactoring suggestions,
  explaining concepts, and general programming questions.
  """

  init(tier: MLXEditorModelTier = .auto) {
    let config: MLXEditorModelConfig
    if tier == .auto {
      config = MLXEditorModelConfig.recommendedModel()
    } else {
      config = MLXEditorModelConfig.model(for: tier) ?? MLXEditorModelConfig.recommendedModel()
    }
    self.config = config
    self.modelName = config.name
    self.tier = config.tier
    self.conversationHistory = [.system(systemMessage)]
  }

  // MARK: - Model Loading

  private func ensureLoaded() async throws {
    guard !isLoaded else { return }
    print("[MLXChat] Loading model: \(config.huggingFaceId)")
    let modelConfig = ModelConfiguration(id: config.huggingFaceId)
    modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig) { progress in
      let percent = Int(progress.fractionCompleted * 100)
      if percent % 10 == 0 {
        print("[MLXChat] Loading: \(percent)%")
      }
    }
    isLoaded = true
    print("[MLXChat] Model ready: \(config.name)")
  }

  // MARK: - Chat

  /// Send a message and get a streaming response
  func sendMessage(_ text: String) async throws -> AsyncStream<String> {
    try await ensureLoaded()

    guard let container = modelContainer else {
      throw MLXChatError.modelNotLoaded
    }

    // Add user message to history
    conversationHistory.append(.user(text))

    // Build fresh messages array for the model
    let messages: [Chat.Message] = Array(conversationHistory)
    nonisolated(unsafe) let input = UserInput(chat: messages)

    let parameters = GenerateParameters(
      maxTokens: config.maxTokens,
      temperature: config.tier == .xlarge ? 1.0 : 0.7,
      topP: config.tier == .xlarge ? 0.95 : 0.9
    )

    let lmInput = try await container.prepare(input: input)
    let stream = try await container.generate(input: lmInput, parameters: parameters)

    // Capture self for the actor-isolated closure
    let history = conversationHistory
    return AsyncStream { continuation in
      Task {
        var fullResponse = ""
        for await generation in stream {
          switch generation {
          case .chunk(let text):
            fullResponse += text
            continuation.yield(text)
          case .info, .toolCall:
            break
          }
        }
        // Add assistant response to history on the actor
        await self.appendAssistantMessage(fullResponse)
        continuation.finish()
      }
    }
  }

  private func appendAssistantMessage(_ text: String) {
    conversationHistory.append(.assistant(text))
  }

  /// Clear conversation history (keep system prompt)
  func clearHistory() {
    conversationHistory = [.system(systemMessage)]
  }

  /// Unload model to free memory
  func unload() {
    modelContainer = nil
    isLoaded = false
    conversationHistory = [.system(systemMessage)]
    print("[MLXChat] Model unloaded")
  }

  func getIsLoaded() -> Bool { isLoaded }
  func getHistoryCount() -> Int { conversationHistory.count - 1 } // minus system prompt
}

// MARK: - Errors

enum MLXChatError: LocalizedError {
  case modelNotLoaded

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded: return "Chat model not loaded"
    }
  }
}

#endif
