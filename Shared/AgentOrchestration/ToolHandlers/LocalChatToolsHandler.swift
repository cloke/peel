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

  /// DataService for skills/context injection
  var dataService: DataService?

  /// The chat service instance — lazily created on first use
  private var chatService: MLXChatService?
  private var currentTier: MLXEditorModelTier = .auto
  private var currentRepoPath: String?

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
    let repoPath = optionalString("repoPath", from: arguments, default: nil)
    let instructions = optionalString("instructions", from: arguments, default: nil)
    let clearHistory = (arguments["clearHistory"] as? Bool) == true

    // Build context from skills + auto-detected instructions
    var context: ChatContext? = await buildContext(repoPath: repoPath)
    if let instructions {
      // Append explicit instructions to any auto-detected ones
      if context != nil {
        if let existing = context?.instructions {
          context?.instructions = existing + "\n\n" + instructions
        } else {
          context?.instructions = instructions
        }
      } else {
        context = ChatContext(instructions: instructions)
      }
    }

    // If tier, repo, or context changed — recreate the service
    let needsNewService = chatService == nil
      || requestedTier != currentTier
      || repoPath != currentRepoPath

    if needsNewService {
      if let old = chatService {
        print("[MCP Chat] Unloading previous model (tier was \(currentTier), now \(requestedTier))")
        await old.unload()
      }
      currentTier = requestedTier
      currentRepoPath = repoPath
      chatService = MLXChatService(tier: requestedTier, context: context ?? .empty)
      print("[MCP Chat] Created service with tier: \(requestedTier), repoPath: \(repoPath ?? "none")")
    } else if let service = chatService {
      // Update context if provided (instructions/skills may have changed)
      if let context {
        await service.updateContext(context)
      }
      // Clear history if requested (keeps context but resets conversation)
      if clearHistory {
        await service.clearHistory()
        print("[MCP Chat] Cleared conversation history")
      }
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

      var result: [String: Any] = [
        "response": fullResponse,
        "model": service.modelName,
        "tier": service.tier.rawValue,
        "tokens": tokenCount,
        "tokensPerSecond": round(tokensPerSecond * 10) / 10,
        "elapsedSeconds": round(elapsed * 10) / 10,
        "historyLength": await service.getHistoryCount(),
      ]
      if let repoPath {
        result["repoPath"] = repoPath
        result["hasSkills"] = context?.skills != nil
      }
      return (200, makeResult(id: id, result: result))
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
            "repoPath": ["type": "string", "description": "Optional: path to a repository to inject relevant skills/context into the chat"],
            "instructions": ["type": "string", "description": "Optional: custom instructions to inject into the system prompt (e.g., framework-specific coding guidelines)"],
            "clearHistory": ["type": "boolean", "description": "If true, clear conversation history before sending (keeps model loaded and context)"],
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

  // MARK: - Context Building

  private func buildContext(repoPath: String?) async -> ChatContext? {
    guard let repoPath, let dataService else { return nil }

    // Auto-seed Ember skills for this repo
    let seeded = await DefaultSkillsService.autoSeedEmberSkillsIfNeeded(
      context: dataService.modelContext,
      repoPath: repoPath
    )
    if seeded > 0 {
      print("[MCP Chat] Auto-seeded \(seeded) Ember skills for \(repoPath)")
    }

    // Fetch skills block — limit to 8 highest-priority to avoid diluting directive rules
    let remoteURL = RepoRegistry.shared.getCachedRemoteURL(for: repoPath)
    let skillsBlock = await dataService.repoGuidanceSkillsBlock(
      repoPath: repoPath,
      repoRemoteURL: remoteURL,
      limit: 8
    )

    var context = ChatContext()

    // Auto-inject directive rules for detected project types.
    // When directive rules are present, skip skills injection —
    // the directive rules are concise and focused; mixing in verbose
    // skill examples dilutes the model's adherence to critical rules.
    let isEmber = DefaultSkillsService.detectEmberProject(repoPath: repoPath)
    if isEmber {
      context.instructions = Self.emberDirectiveRules
      print("[MCP Chat] Injected Ember directive rules for \(repoPath)")
    } else if let (block, _) = skillsBlock {
      // Only inject skills when no directive rules are present
      context.skills = block
    }

    return context.isEmpty ? nil : context
  }

  // MARK: - Ember Directive Rules

  /// Concise, directive rules that are always injected for Ember projects.
  /// Skills provide reference examples; these rules provide firm constraints.
  private static let emberDirectiveRules = """
  MANDATORY IMPORTS FOR .gjs FILES — missing imports crash at runtime:
  - `import Component from '@glimmer/component';` — ALWAYS
  - `import { tracked } from '@glimmer/tracking';` — if you use @tracked
  - `import { on } from '@ember/modifier';` — if template uses {{on "click" ...}} or any {{on ...}}
  - `import { fn } from '@ember/helper';` — if template uses (fn ...)

  EXAMPLE 1 — List with per-item action (uses `on` AND `fn`):
  ```gjs
  import Component from '@glimmer/component';
  import { tracked } from '@glimmer/tracking';
  import { on } from '@ember/modifier';
  import { fn } from '@ember/helper';

  export default class TodoList extends Component {
    @tracked items = ['Buy milk', 'Walk dog'];

    deleteItem = (item) => {
      this.items = this.items.filter(i => i !== item);
    };

    <template>
      <ul>
        {{#each this.items as |item|}}
          <li>
            {{item}}
            <button type="button" {{on "click" (fn this.deleteItem item)}}>Delete</button>
          </li>
        {{/each}}
      </ul>
    </template>
  }
  ```
  ↑ `fn` IS imported because template uses `(fn this.deleteItem item)`.

  EXAMPLE 2 — Simple button (uses `on`, no `fn`):
  ```gjs
  import Component from '@glimmer/component';
  import { tracked } from '@glimmer/tracking';
  import { on } from '@ember/modifier';

  export default class ToggleButton extends Component {
    @tracked isActive = false;

    toggle = () => {
      this.isActive = !this.isActive;
    };

    get label() {
      return this.isActive ? 'On' : 'Off';
    }

    <template>
      <button type="button" {{on "click" this.toggle}}>{{this.label}}</button>
    </template>
  }
  ```
  ↑ `on` IS imported because template uses `{{on "click" this.toggle}}`. No `fn` needed here.

  TEMPLATE RULES:
  - Glimmer templates are NOT JavaScript — no ternary, no arithmetic, no comparisons
  - Use {{#if}} for conditionals, getters for computed values
  - Arrow function class properties for handlers (NOT @action decorator)
  - {{this.prop}} for own state, {{@argName}} for parent args
  - Reassign arrays: this.items = [...this.items, newItem]
  - Input: <input value={{this.val}} {{on "input" this.updateVal}} />
  - Handler: updateVal = (event) => { this.val = event.target.value; };
  - Place handlers/getters BEFORE <template>
  - NEVER use @action, {{action}}, {{mut}}, this.set(), inline arrows in templates
  """

  private func getMemoryGB() -> Double {
    var size = 0
    var sizeOfSize = MemoryLayout<Int>.size
    sysctlbyname("hw.memsize", &size, &sizeOfSize, nil, 0)
    return Double(size) / 1_073_741_824.0
  }
}

#endif
