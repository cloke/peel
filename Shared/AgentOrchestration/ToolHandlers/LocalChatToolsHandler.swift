//
//  LocalChatToolsHandler.swift
//  Peel
//
//  MCP tool handler for local chat via MLX models.
//  Delegates to SharedChatSession so messages appear in the UI in real time.
//
//  Created on 2/24/26.
//

import Foundation
import MCPCore

// MARK: - Local Chat Tools Handler

final class LocalChatToolsHandler: MCPToolHandler {
  weak var delegate: MCPToolHandlerDelegate?

  /// DataService for skills/context injection
  var dataService: DataService?

  /// MCPServerService for RAG search access
  weak var mcpServer: MCPServerService?

  /// Shared chat session — messages and streaming state visible in the UI
  var chatSession: SharedChatSession?

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
      return await handleStatus(id: id)
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

    guard let session = chatSession else {
      return internalError(id: id, message: "Chat session not available")
    }

    let tierString = optionalString("tier", from: arguments, default: "auto") ?? "auto"
    let requestedTier = parseTier(tierString)
    let repoPath = optionalString("repoPath", from: arguments, default: nil)
    let instructions = optionalString("instructions", from: arguments, default: nil)
    let clearHistory = (arguments["clearHistory"] as? Bool) == true
    let useToolCalling = (arguments["useToolCalling"] as? Bool) ?? true

    // Build context from skills + auto-detected instructions
    var context: ChatContext? = await buildContext(repoPath: repoPath)
    if let instructions {
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

    // Update repo path and tool calling preference on shared session
    await MainActor.run {
      if let repoPath {
        session.selectedRepoPath = repoPath
      }
      session.useToolCalling = useToolCalling
    }

    do {
      let result = try await session.send(
        message,
        dataService: dataService,
        mcpServer: mcpServer,
        context: context,
        tier: requestedTier,
        clearHistory: clearHistory,
        source: .mcp
      )

      let service = session.chatService
      let modelName = service?.modelName ?? "unknown"
      let tierValue = service?.tier.rawValue ?? requestedTier.rawValue
      let historyCount = await service?.getHistoryCount() ?? 0

      var responseDict: [String: Any] = [
        "response": result.response,
        "model": modelName,
        "tier": tierValue,
        "tokens": result.tokens,
        "tokensPerSecond": round(Double(result.tokens) / max(result.elapsed, 0.001) * 10) / 10,
        "elapsedSeconds": round(result.elapsed * 10) / 10,
        "historyLength": historyCount,
      ]
      if let repoPath {
        responseDict["repoPath"] = repoPath
        responseDict["hasSkills"] = context?.skills != nil
      }
      return (200, makeResult(id: id, result: responseDict))
    } catch {
      return internalError(id: id, message: "Chat error: \(error.localizedDescription)")
    }
  }

  // MARK: - chat.status

  private func handleStatus(id: Any?) async -> (Int, Data) {
    let memGB = getMemoryGB()
    let recommendedTier = MLXEditorModelTier.recommended(forMemoryGB: memGB)
    let recommendedConfig = MLXEditorModelConfig.recommendedModel()

    let session = chatSession
    let currentTier = session?.selectedTier ?? .auto
    let isLoaded = session?.isModelLoaded ?? false

    var result: [String: Any] = [
      "machineRamGB": Int(memGB),
      "recommendedTier": recommendedTier.rawValue,
      "recommendedModel": recommendedConfig.name,
      "recommendedHuggingFaceId": recommendedConfig.huggingFaceId,
      "currentTier": currentTier.rawValue,
      "isLoaded": isLoaded,
      "availableModels": MLXEditorModelConfig.availableModels.map { model in
        [
          "name": model.name,
          "tier": model.tier.rawValue,
          "huggingFaceId": model.huggingFaceId,
          "contextLength": model.contextLength,
        ] as [String: Any]
      },
    ]

    if let service = session?.chatService {
      result["loadedModel"] = service.modelName
      result["loadedTier"] = service.tier.rawValue
    }

    return (200, makeResult(id: id, result: result))
  }

  // MARK: - chat.unload

  private func handleUnload(id: Any?) async -> (Int, Data) {
    guard let session = chatSession else {
      return (200, makeResult(id: id, result: [
        "message": "No chat session available",
        "wasLoaded": false,
      ]))
    }

    let wasLoaded = session.isModelLoaded
    session.unloadModel()

    return (200, makeResult(id: id, result: [
      "message": wasLoaded ? "Chat model unloaded — memory freed" : "No chat model was loaded",
      "wasLoaded": wasLoaded,
    ]))
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "chat.send",
        description: "Send a message to the local MLX chat model and get a response. Messages appear in the Peel chat UI in real time. The model is loaded lazily on first call (~45GB download for xlarge tier). macOS only.",
        inputSchema: [
          "type": "object",
          "properties": [
            "message": ["type": "string", "description": "The message to send to the chat model"],
            "tier": ["type": "string", "description": "Model tier: auto, small, medium, large, xlarge (default: auto)"],
            "repoPath": ["type": "string", "description": "Optional: path to a repository to inject relevant skills/context into the chat"],
            "instructions": ["type": "string", "description": "Optional: custom instructions to inject into the system prompt (e.g., framework-specific coding guidelines)"],
            "clearHistory": ["type": "boolean", "description": "If true, clear conversation history before sending (keeps model loaded and context)"],
            "useToolCalling": ["type": "boolean", "description": "Enable tool calling (rag_search, dispatch_chain, chain_status). Default: true"],
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
    let seeded = DefaultSkillsService.autoSeedEmberSkillsIfNeeded(
      context: dataService.modelContext,
      repoPath: repoPath
    )
    if seeded > 0 {
      print("[MCP Chat] Auto-seeded \(seeded) Ember skills for \(repoPath)")
    }

    // Fetch skills block
    let remoteURL = RepoRegistry.shared.getCachedRemoteURL(for: repoPath)
    let skillsBlock = dataService.repoGuidanceSkillsBlock(
      repoPath: repoPath,
      repoRemoteURL: remoteURL,
      limit: 8
    )

    var context = ChatContext()

    // Auto-inject directive rules for detected project types.
    let directivesPath = (repoPath as NSString).appendingPathComponent(".peel/directives.md")
    let repoDirectives = try? String(contentsOfFile: directivesPath, encoding: .utf8)

    if let directives = repoDirectives, !directives.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      context.instructions = directives
      print("[MCP Chat] Injected repo-local directives from .peel/directives.md for \(repoPath)")
    } else {
      let detection = FrameworkDetector.detect(repoPath: repoPath)
      if detection.primary != .unknown {
        let directives = detection.primary == .ember ? Self.emberDirectiveRules : detection.directiveContent
        context.instructions = directives
        print("[MCP Chat] Injected \(detection.primary.rawValue) directive rules for \(repoPath)")
      } else if let (block, _) = skillsBlock {
        context.skills = block
      }
    }

    return context.isEmpty ? nil : context
  }

  // MARK: - Ember Directive Rules

  /// Concise, directive rules that are always injected for Ember projects.
  static let emberDirectiveRules = """
  .gjs FILE FORMAT — CRITICAL RULES (READ BEFORE WRITING CODE)

  ⚠️ RULE 1 — IMPORTS: Every `{{on ...}}` in template REQUIRES `import { on } from '@ember/modifier';`
  Every `(fn ...)` in template REQUIRES `import { fn } from '@ember/helper';`
  Missing imports = runtime crash. Scan your <template> for {{on}} and (fn), then add matching imports.

  ⚠️ RULE 2 — fn USAGE: `fn` only curries existing methods: `(fn this.myMethod arg)`.
  NEVER write `(fn (x) => ...)` or `(fn someInlineFunction)`. fn is NOT a lambda/closure.
  For input handlers, write a class method: `handleInput = (event) => { this.val = event.target.value; };`
  Then use: `{{on "input" this.handleInput}}`

  ⚠️ RULE 3 — NO <script> tags. .gjs is NOT Vue/Svelte. There is no <script> block.

  PATTERN A — Template-only (no state, no handlers, args only):
  ```gjs
  <template>
    <button
      class="ui-button {{@variant}}"
      type={{if @type @type "button"}}
      disabled={{@disabled}}
      ...attributes
    >
      {{yield}}
    </button>
  </template>
  ```
  ↑ No imports, no class. Just <template> at top level. Use {{@argName}} for args.

  PATTERN B — Class component (has state or handlers):
  Imports at top, <template> INSIDE the class body.

  Example with on + fn (note: both are imported because both are used in the template):
  ```gjs
  import Component from '@glimmer/component';
  import { tracked } from '@glimmer/tracking';
  import { on } from '@ember/modifier';  // ← REQUIRED: template uses {{on ...}}
  import { fn } from '@ember/helper';    // ← REQUIRED: template uses (fn ...)

  export default class TodoList extends Component {
    @tracked items = ['Buy milk', 'Walk dog'];
    @tracked newItem = '';

    handleInput = (event) => {
      this.newItem = event.target.value;
    };

    addItem = () => {
      if (this.newItem.trim()) {
        this.items = [...this.items, this.newItem.trim()];
        this.newItem = '';
      }
    };

    deleteItem = (item) => {
      this.items = this.items.filter(i => i !== item);
    };

    <template>
      <div>
        <input type="text" value={{this.newItem}} {{on "input" this.handleInput}} />
        <button type="button" {{on "click" this.addItem}}>Add</button>
        <ul>
          {{#each this.items as |item|}}
            <li>
              {{item}}
              <button type="button" {{on "click" (fn this.deleteItem item)}}>Delete</button>
            </li>
          {{/each}}
        </ul>
      </div>
    </template>
  }
  ```

  Example with on only (no fn needed):
  ```gjs
  import Component from '@glimmer/component';
  import { tracked } from '@glimmer/tracking';
  import { on } from '@ember/modifier';  // ← REQUIRED: template uses {{on ...}}

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

  TEMPLATE RULES:
  - Glimmer templates are NOT JavaScript — no ternary, no arithmetic, no comparisons
  - Use {{#if}} for conditionals, getters for computed values
  - Arrow function class properties for handlers (NOT @action decorator)
  - {{this.prop}} for own state, {{@argName}} for parent args
  - {{yield}} to render child content passed by parent
  - ...attributes to pass through HTML attributes
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

