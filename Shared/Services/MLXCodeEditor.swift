//
//  MLXCodeEditor.swift
//  Peel
//
//  Local code editor using MLX LLM models.
//  Generates unified diffs, refactoring suggestions, and code completions
//  using a locally-running model on Apple Silicon.
//
//  Model tiers:
//    Small  - Qwen2.5-Coder-7B  (24-48GB RAM)
//    Medium - Qwen2.5-Coder-14B (48-96GB RAM)
//    Large  - Qwen3-Coder-30B-A3B MoE (96GB+ RAM, qwen3_moe arch)
//    XLarge - Qwen3-Coder-Next 80B MoE (128GB+ RAM, qwen3_next arch)
//
//  Created on 2/10/26.
//

#if os(macOS)
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Editor Model Configuration

/// Editor model tiers — larger than analyzer models because editing needs reasoning
enum MLXEditorModelTier: String, CaseIterable, Sendable {
  /// Auto-select based on available RAM
  case auto

  /// Small models (~7B) - good for machines with 24-48GB RAM
  /// Simple completions, rename-style refactors
  case small

  /// Medium models (~14B) - good for machines with 48-96GB RAM
  /// Moderate refactors, extract method, add protocol conformance
  case medium

  /// Large models (Qwen3-Coder-30B-A3B MoE, 3B active) - 96GB+ RAM
  /// Full agentic edits: multi-file refactors, architecture changes
  case large

  /// XLarge models (Qwen3-Coder-Next 80B MoE, 3B active) - 128GB+ RAM
  /// Best local coding model; hybrid DeltaNet + Attention + MoE architecture
  case xlarge

  var description: String {
    switch self {
    case .auto: return "Auto (based on RAM)"
    case .small: return "Small (24-48GB RAM) - Qwen2.5-Coder-7B"
    case .medium: return "Medium (48-96GB RAM) - Qwen2.5-Coder-14B"
    case .large: return "Large (96GB+ RAM) - Qwen3-Coder-30B MoE"
    case .xlarge: return "XLarge (128GB+ RAM) - Qwen3-Coder-Next"
    }
  }

  var modelName: String {
    switch self {
    case .auto: return "Auto"
    case .small: return "Qwen2.5-Coder-7B"
    case .medium: return "Qwen2.5-Coder-14B"
    case .large: return "Qwen3-Coder-30B"
    case .xlarge: return "Qwen3-Coder-Next"
    }
  }

  /// Get recommended tier for given RAM
  static func recommended(forMemoryGB gb: Double) -> MLXEditorModelTier {
    if gb >= 128 {
      return .xlarge  // Mac Studio Ultra 192GB+, Mac Pro
    } else if gb >= 96 {
      return .large   // Mac Studio Ultra 96GB+
    } else if gb >= 48 {
      return .medium  // Mac Studio 64GB
    } else if gb >= 24 {
      return .small   // MacBook Pro 32GB
    } else {
      return .small   // Fallback — editing needs at least 7B
    }
  }
}

/// Configuration for an MLX code editor model
struct MLXEditorModelConfig: Sendable {
  let name: String
  let huggingFaceId: String
  let tier: MLXEditorModelTier
  let maxTokens: Int
  let contextLength: Int

  /// Available models for code editing — larger than analyzer models
  static let availableModels: [MLXEditorModelConfig] = [
    // Small tier - Qwen2.5-Coder-7B (simple edits on smaller machines)
    MLXEditorModelConfig(
      name: "Qwen2.5-Coder-7B",
      huggingFaceId: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
      tier: .small,
      maxTokens: 4096,
      contextLength: 32768
    ),

    // Medium tier - Qwen2.5-Coder-14B (moderate refactors)
    MLXEditorModelConfig(
      name: "Qwen2.5-Coder-14B",
      huggingFaceId: "lmstudio-community/Qwen2.5-Coder-14B-Instruct-MLX-4bit",
      tier: .medium,
      maxTokens: 8192,
      contextLength: 65536
    ),

    // Large tier - Qwen3-Coder-30B-A3B MoE (qwen3_moe architecture, ~3B active)
    // Good MoE model for machines with 96GB+ RAM.
    // Requires ~10-15GB RAM at 4-bit quantization.
    MLXEditorModelConfig(
      name: "Qwen3-Coder-30B",
      huggingFaceId: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
      tier: .large,
      maxTokens: 16384,
      contextLength: 131072  // 128K context
    ),

    // XLarge tier - Qwen3-Coder-Next 80B MoE (qwen3_next architecture, 3B active)
    // Best local coding model. Hybrid DeltaNet + Attention + MoE with 512 experts.
    // Requires ~45GB RAM at 4-bit quantization. 128GB+ recommended.
    // Recommended sampling: temperature=1.0, top_p=0.95, top_k=40
    MLXEditorModelConfig(
      name: "Qwen3-Coder-Next",
      huggingFaceId: "mlx-community/Qwen3-Coder-Next-4bit",
      tier: .xlarge,
      maxTokens: 32768,
      contextLength: 262144  // 256K context
    )
  ]

  /// Select the best model for the current machine's RAM
  static func recommendedModel() -> MLXEditorModelConfig {
    let availableMemoryGB = getAvailableMemoryGB()
    let tier = MLXEditorModelTier.recommended(forMemoryGB: availableMemoryGB)
    return availableModels.first { $0.tier == tier } ?? availableModels[0]
  }

  /// Get model for a specific tier
  static func model(for tier: MLXEditorModelTier) -> MLXEditorModelConfig? {
    availableModels.first { $0.tier == tier }
  }

  private static func getAvailableMemoryGB() -> Double {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return Double(size) / 1_073_741_824.0
  }
}

// MARK: - Edit Request & Result Types

/// What kind of edit the caller wants
enum MLXEditMode: String, Sendable {
  /// Generate a unified diff for the given instruction
  case diff

  /// Return the full edited file content
  case fullFile

  /// Return only the code block that changed
  case snippet
}

/// Input to the code editor
struct MLXEditRequest: Sendable {
  /// The source code to edit
  let sourceCode: String

  /// Natural-language instruction (e.g., "extract the validation into a protocol")
  let instruction: String

  /// Optional language hint (e.g., "swift", "python")
  let language: String?

  /// Optional file path for context
  let filePath: String?

  /// Additional context — e.g., related code from RAG search
  let relatedContext: String?

  /// Desired output format
  let mode: MLXEditMode
}

/// Result of a code edit
struct MLXEditResult: Sendable {
  /// The model's edit output (diff, full file, or snippet depending on mode)
  let editedContent: String

  /// Brief explanation of what was changed
  let explanation: String

  /// Which model produced this edit
  let model: String

  /// How long generation took
  let durationMs: Int

  /// Tokens generated
  let tokensGenerated: Int
}

// MARK: - MLX Code Editor Actor

/// Edits code using local MLX LLM models.
/// On machines with 96GB+ RAM, uses Qwen3-Coder-30B-A3B (MoE, ~3B active)
/// for high-quality agentic code edits entirely on-device.
actor MLXCodeEditor {
  private var modelContainer: ModelContainer?
  private let config: MLXEditorModelConfig
  private var isLoaded = false

  nonisolated let modelName: String
  nonisolated let tier: MLXEditorModelTier

  /// Create editor with specific model configuration
  init(config: MLXEditorModelConfig) {
    self.config = config
    self.modelName = config.name
    self.tier = config.tier
  }

  /// Create editor with auto-detected best model for the machine
  init() {
    let config = MLXEditorModelConfig.recommendedModel()
    print("[MLXEditor] Selected model: \(config.name) (tier: \(config.tier))")
    self.config = config
    self.modelName = config.name
    self.tier = config.tier
  }

  /// Create editor for a specific tier
  init(tier: MLXEditorModelTier) {
    let config = MLXEditorModelConfig.model(for: tier) ?? MLXEditorModelConfig.recommendedModel()
    print("[MLXEditor] Selected model: \(config.name) (tier: \(tier))")
    self.config = config
    self.modelName = config.name
    self.tier = tier
  }

  // MARK: - Model Loading

  /// Load the model (lazy — called on first edit)
  private func ensureLoaded() async throws {
    guard !isLoaded else { return }

    print("[MLXEditor] Loading model: \(config.huggingFaceId)")

    let modelConfig = ModelConfiguration(id: config.huggingFaceId)

    modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig) { progress in
      let percent = Int(progress.fractionCompleted * 100)
      print("[MLXEditor] Loading: \(percent)% - \(progress.localizedDescription ?? "")")
    }

    isLoaded = true
    print("[MLXEditor] Model ready: \(config.name)")
  }

  // MARK: - Code Editing

  /// Edit code based on a natural-language instruction
  func edit(_ request: MLXEditRequest) async throws -> MLXEditResult {
    try await ensureLoaded()

    guard let container = modelContainer else {
      throw MLXEditorError.modelNotLoaded
    }

    let startTime = Date()

    // Build the prompt
    let prompt = buildEditPrompt(request)

    // Create chat messages
    let messages: [Chat.Message] = [
      .system(systemPrompt(for: request.mode)),
      .user(prompt)
    ]

    let userInput = UserInput(chat: messages)
    let lmInput = try await container.prepare(input: userInput)

    let parameters = GenerateParameters(
      maxTokens: config.maxTokens,
      temperature: 0.2,  // Low-ish for code editing — deterministic but not rigid
      topP: 0.95
    )

    // Stream generation
    var outputText = ""
    var tokenCount = 0
    let stream = try await container.generate(input: lmInput, parameters: parameters)

    for await generation in stream {
      switch generation {
      case .chunk(let text):
        outputText += text
        tokenCount += 1
      case .info:
        break
      case .toolCall:
        break
      }
    }

    let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

    // Parse the response
    let parsed = parseEditResponse(outputText, mode: request.mode)

    return MLXEditResult(
      editedContent: parsed.content,
      explanation: parsed.explanation,
      model: config.name,
      durationMs: durationMs,
      tokensGenerated: tokenCount
    )
  }

  /// Stream an edit — returns an AsyncStream of chunks for real-time UI
  func editStreaming(_ request: MLXEditRequest) async throws -> AsyncStream<String> {
    try await ensureLoaded()

    guard let container = modelContainer else {
      throw MLXEditorError.modelNotLoaded
    }

    let prompt = buildEditPrompt(request)
    let messages: [Chat.Message] = [
      .system(systemPrompt(for: request.mode)),
      .user(prompt)
    ]

    let userInput = UserInput(chat: messages)
    let lmInput = try await container.prepare(input: userInput)

    let parameters = GenerateParameters(
      maxTokens: config.maxTokens,
      temperature: 0.2,
      topP: 0.95
    )

    let stream = try await container.generate(input: lmInput, parameters: parameters)

    return AsyncStream { continuation in
      Task {
        for await generation in stream {
          switch generation {
          case .chunk(let text):
            continuation.yield(text)
          case .info, .toolCall:
            break
          }
        }
        continuation.finish()
      }
    }
  }

  /// Unload the model to free memory
  func unload() {
    modelContainer = nil
    isLoaded = false
    print("[MLXEditor] Model unloaded: \(config.name)")
  }

  /// Check if the model is loaded and how much memory it's using
  func status() -> MLXEditorStatus {
    MLXEditorStatus(
      modelName: config.name,
      tier: config.tier,
      isLoaded: isLoaded,
      huggingFaceId: config.huggingFaceId,
      maxTokens: config.maxTokens,
      contextLength: config.contextLength
    )
  }

  // MARK: - Prompt Building

  private func systemPrompt(for mode: MLXEditMode) -> String {
    switch mode {
    case .diff:
      return """
      You are a precise code editing assistant. Given source code and an instruction,
      produce a unified diff (--- a/file, +++ b/file format) that implements the requested change.

      Rules:
      - Output ONLY the unified diff, no explanation before or after
      - Use proper unified diff format with @@ line markers
      - Include 3 lines of context around changes
      - After the diff, add a single line starting with "EXPLANATION:" followed by a brief summary
      - Preserve the original code style (indentation, naming conventions, etc.)
      - Make minimal changes — don't rewrite code that doesn't need to change
      """

    case .fullFile:
      return """
      You are a precise code editing assistant. Given source code and an instruction,
      return the complete edited file.

      Rules:
      - Output the COMPLETE file content, not just the changed parts
      - After the file content (delimited by triple backticks), add "EXPLANATION:" on a new line
      - Preserve the original code style (indentation, naming conventions, etc.)
      - Make minimal changes — don't rewrite code that doesn't need to change
      """

    case .snippet:
      return """
      You are a precise code editing assistant. Given source code and an instruction,
      return only the changed code block(s).

      Rules:
      - Output only the changed function/method/block, not the entire file
      - Include enough surrounding context (function signature, closing brace) for unambiguous placement
      - After the code, add "EXPLANATION:" on a new line with a brief summary
      - Preserve the original code style (indentation, naming conventions, etc.)
      """
    }
  }

  private func buildEditPrompt(_ request: MLXEditRequest) -> String {
    var parts: [String] = []

    if let filePath = request.filePath {
      parts.append("File: \(filePath)")
    }
    if let language = request.language {
      parts.append("Language: \(language)")
    }

    parts.append("")
    parts.append("Source code:")
    parts.append("```")
    // Truncate to fit context — reserve space for instruction + output
    let maxSourceChars = config.contextLength * 3  // ~3 chars per token, rough estimate
    let truncated = String(request.sourceCode.prefix(maxSourceChars))
    parts.append(truncated)
    parts.append("```")

    if let related = request.relatedContext, !related.isEmpty {
      parts.append("")
      parts.append("Related code from the repository (for style reference):")
      parts.append("```")
      parts.append(String(related.prefix(4000)))
      parts.append("```")
    }

    parts.append("")
    parts.append("Instruction: \(request.instruction)")

    return parts.joined(separator: "\n")
  }

  // MARK: - Response Parsing

  private func parseEditResponse(_ response: String, mode: MLXEditMode) -> (content: String, explanation: String) {
    // Split on EXPLANATION: marker
    let parts = response.components(separatedBy: "EXPLANATION:")
    let content: String
    let explanation: String

    if parts.count >= 2 {
      content = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      explanation = parts[1...].joined(separator: "EXPLANATION:").trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      content = response.trimmingCharacters(in: .whitespacesAndNewlines)
      explanation = "Edit applied"
    }

    // For fullFile and snippet modes, strip code fences if present
    if mode == .fullFile || mode == .snippet {
      return (stripCodeFences(content), explanation)
    }

    return (content, explanation)
  }

  private func stripCodeFences(_ text: String) -> String {
    var result = text
    // Remove leading ```language
    if let range = result.range(of: "^```\\w*\\n", options: .regularExpression) {
      result.removeSubrange(range)
    }
    // Remove trailing ```
    if let range = result.range(of: "\\n```$", options: .regularExpression) {
      result.removeSubrange(range)
    }
    return result
  }
}

// MARK: - Status

struct MLXEditorStatus: Sendable {
  let modelName: String
  let tier: MLXEditorModelTier
  let isLoaded: Bool
  let huggingFaceId: String
  let maxTokens: Int
  let contextLength: Int
}

// MARK: - Errors

enum MLXEditorError: LocalizedError {
  case modelNotLoaded
  case editFailed(String)
  case contextTooLong
  case unsupportedOnDevice

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded: return "MLX editor model not loaded"
    case .editFailed(let reason): return "Code edit failed: \(reason)"
    case .contextTooLong: return "Source code exceeds model context length"
    case .unsupportedOnDevice: return "Code editing requires at least 24GB RAM"
    }
  }
}

// MARK: - Factory

enum MLXCodeEditorFactory {
  /// User's preferred editor tier (nil = auto-detect)
  @MainActor static var preferredTier: MLXEditorModelTier?

  /// Whether local code editing is enabled
  @MainActor static var editingEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "mlx.editor.enabled") }
    set { UserDefaults.standard.set(newValue, forKey: "mlx.editor.enabled") }
  }

  /// Create editor with user preference or auto-detect
  @MainActor static func makeEditor() -> MLXCodeEditor {
    if let tier = preferredTier {
      return MLXCodeEditor(tier: tier)
    }
    return MLXCodeEditor()
  }

  /// Create editor with specific tier
  nonisolated static func makeEditor(tier: MLXEditorModelTier) -> MLXCodeEditor {
    MLXCodeEditor(tier: tier)
  }

  /// Get recommended tier description for the current machine
  nonisolated static func recommendedTierDescription() -> String {
    let config = MLXEditorModelConfig.recommendedModel()
    let memGB = Int(getAvailableMemoryGB())
    return "\(config.name) recommended for \(memGB)GB RAM"
  }

  /// Check if local editing is feasible on this machine (need 24GB+ RAM)
  nonisolated static func isEditingFeasible() -> Bool {
    getAvailableMemoryGB() >= 24
  }

  private nonisolated static func getAvailableMemoryGB() -> Double {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return Double(size) / 1_073_741_824.0
  }
}

#endif
