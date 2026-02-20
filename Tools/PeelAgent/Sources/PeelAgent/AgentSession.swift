import Foundation

/// The main agent session — manages conversation, tool execution, and the interactive loop
final class AgentSession: Sendable {
  private let provider: any LLMProvider
  private let toolExecutor: ToolExecutor
  private let autoApprove: Bool
  private let tools: [ToolDefinition]

  // Mutable state protected by actor isolation via nonisolated(unsafe)
  // (only accessed from the main async context in practice)
  nonisolated(unsafe) private var conversationHistory: [MessagesRequest.Message] = []
  nonisolated(unsafe) private var totalInputTokens: Int = 0
  nonisolated(unsafe) private var totalOutputTokens: Int = 0

  private let systemPrompt: String

  init(
    provider: any LLMProvider,
    toolExecutor: ToolExecutor,
    autoApprove: Bool
  ) {
    self.provider = provider
    self.toolExecutor = toolExecutor
    self.autoApprove = autoApprove
    self.tools = AgentTools.all()
    self.systemPrompt = Self.buildSystemPrompt(workDir: toolExecutor.workingDirectory)
  }

  // MARK: - Interactive Loop

  func runInteractiveLoop() async {
    while true {
      guard let input = Terminal.prompt() else {
        break
      }

      let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }

      // Handle special commands
      switch trimmed.lowercased() {
      case "quit", "exit", "q":
        Terminal.info("Goodbye!")
        return
      case "clear":
        conversationHistory.removeAll()
        Terminal.success("Conversation cleared")
        continue
      case "history":
        Terminal.info("Messages: \(conversationHistory.count)")
        Terminal.info("Tokens: \(totalInputTokens) in / \(totalOutputTokens) out")
        continue
      case "help":
        printHelp()
        continue
      default:
        break
      }

      await processUserMessage(trimmed)
    }
  }

  // MARK: - Single prompt mode

  func runSinglePrompt(_ text: String) async {
    await processUserMessage(text)
  }

  // MARK: - Message Processing

  private func processUserMessage(_ text: String) async {
    // Add user message to history
    conversationHistory.append(.init(role: "user", content: .text(text)))

    // Run the agent loop — keep going while Claude wants to use tools
    await runAgentLoop()
  }

  private func runAgentLoop() async {
    var iterations = 0
    let maxIterations = 25 // Safety limit

    while iterations < maxIterations {
      iterations += 1

      do {
        // Stream the response
        let response = try await streamResponse()

        // Track usage
        totalInputTokens += response.inputTokens
        totalOutputTokens += response.outputTokens

        // Check if there are tool calls
        let toolCalls = response.toolCalls
        if toolCalls.isEmpty {
          // No tool calls — the agent is done with this turn
          // Add assistant message to history
          conversationHistory.append(.init(role: "assistant", content: .blocks(response.contentBlocks)))
          break
        }

        // Add assistant message (with tool use blocks) to history
        conversationHistory.append(.init(role: "assistant", content: .blocks(response.contentBlocks)))

        // Execute each tool call
        var toolResults: [ContentBlock] = []
        for (name, id, input) in toolCalls {
          let result = await executeToolWithApproval(name: name, id: id, input: input)
          toolResults.append(.toolResult(toolUseId: id, content: result.content, isError: result.isError))
        }

        // Add tool results as a user message
        conversationHistory.append(.init(role: "user", content: .blocks(toolResults)))

      } catch {
        Terminal.error("\(error)")
        break
      }
    }

    if iterations >= maxIterations {
      Terminal.warning("Reached maximum iterations (\(maxIterations)). Stopping.")
    }

    print() // Final newline
  }

  // MARK: - Streaming

  private func streamResponse() async throws -> AgentResponse {
    let stream = try await provider.stream(
      messages: conversationHistory,
      system: systemPrompt,
      tools: tools
    )

    var contentBlocks: [ContentBlock] = []
    var currentTextBuffer = ""
    var currentToolName: String?
    var currentToolId: String?
    var currentToolJSON = ""
    var toolCalls: [(name: String, id: String, input: [String: JSONValue])] = []
    var inputTokens = 0
    var outputTokens = 0

    for await event in stream {
      switch event {
      case .messageStart(let msg):
        inputTokens = msg.usage.input_tokens
        outputTokens = msg.usage.output_tokens

      case .contentBlockStart(_, let block):
        switch block {
        case .text:
          currentTextBuffer = ""
        case .toolUse(let id, let name, _):
          currentToolId = id
          currentToolName = name
          currentToolJSON = ""
          // Show tool call indicator
          print() // newline after any text
          Terminal.toolCall(name)
        default:
          break
        }

      case .contentBlockDelta(_, let delta):
        if delta.type == "text_delta", let text = delta.text {
          Terminal.streamText(text)
          currentTextBuffer += text
        } else if delta.type == "input_json_delta", let json = delta.partial_json {
          currentToolJSON += json
        }

      case .contentBlockStop:
        if !currentTextBuffer.isEmpty {
          contentBlocks.append(.text(currentTextBuffer))
          currentTextBuffer = ""
        }
        if let toolName = currentToolName, let toolId = currentToolId {
          // Parse accumulated JSON
          let input: [String: JSONValue]
          if let data = currentToolJSON.data(using: .utf8),
             let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            input = parsed
          } else {
            input = [:]
          }

          contentBlocks.append(.toolUse(id: toolId, name: toolName, input: input))
          toolCalls.append((name: toolName, id: toolId, input: input))

          currentToolName = nil
          currentToolId = nil
          currentToolJSON = ""
        }

      case .messageDelta(_, let usage):
        if let u = usage {
          outputTokens += u.output_tokens
        }

      case .messageStop:
        break

      case .ping:
        break

      case .error(let msg):
        Terminal.error("Stream error: \(msg)")
      }
    }

    return AgentResponse(
      contentBlocks: contentBlocks,
      toolCalls: toolCalls,
      inputTokens: inputTokens,
      outputTokens: outputTokens
    )
  }

  // MARK: - Tool Execution

  private func executeToolWithApproval(
    name: String,
    id: String,
    input: [String: JSONValue]
  ) async -> ToolResult {
    // Show what we're about to do
    let summary = summarizeToolCall(name: name, input: input)

    if !autoApprove && toolExecutor.requiresApproval(name, input: input) {
      if !Terminal.confirm("Execute \(name): \(summary)?") {
        Terminal.info("Skipped")
        return .error("User declined to execute this tool")
      }
    }

    let result = await toolExecutor.execute(name: name, input: input)

    // Show result (truncated)
    if result.isError {
      Terminal.error(result.content)
    } else {
      Terminal.toolResult(result.content)
    }

    return result
  }

  private func summarizeToolCall(name: String, input: [String: JSONValue]) -> String {
    switch name {
    case "read_file":
      return input["path"]?.stringValue ?? ""
    case "write_file":
      let path = input["path"]?.stringValue ?? ""
      let lines = input["content"]?.stringValue?.components(separatedBy: "\n").count ?? 0
      return "\(path) (\(lines) lines)"
    case "replace_in_file":
      let path = input["path"]?.stringValue ?? ""
      return "edit \(path)"
    case "list_directory":
      return input["path"]?.stringValue ?? "."
    case "search_files":
      let mode = input["mode"]?.stringValue ?? "content"
      return "\(mode): \(input["pattern"]?.stringValue ?? "")"
    case "run_command":
      return input["command"]?.stringValue ?? ""
    case "git_commit":
      return input["message"]?.stringValue ?? ""
    default:
      return name
    }
  }

  // MARK: - System Prompt

  private static func buildSystemPrompt(workDir: String) -> String {
    """
    You are Peel, an expert AI coding agent running in the user's terminal. You help with coding tasks by reading files, writing code, running commands, and using git.

    ## Environment
    - Working directory: \(workDir)
    - OS: macOS
    - Shell: zsh

    ## Guidelines
    - Be direct and concise. Skip unnecessary preamble.
    - When asked to make changes, DO the changes — don't just explain what to do.
    - Read files before editing them to understand the current state.
    - After making changes, verify them (run tests, check for errors).
    - Use git to track your changes. Commit logically.
    - When searching for code, use search_files with content mode for text search.
    - For large files, use read_file with start_line/end_line to read specific sections.

    ## Tool Usage
    - read_file: Read file contents or specific line ranges
    - write_file: Create or overwrite files
    - list_directory: See what's in a directory
    - search_files: Grep for content or find files by name
    - run_command: Execute shell commands
    - git_status, git_diff, git_log: Inspect repo state
    - git_commit: Stage and commit changes

    ## Style
    - Keep responses short. Use tools rather than explaining steps.
    - Show code diffs or relevant snippets when helpful.
    - If something is unclear, ask — but try to infer the most useful action.
    """
  }

  // MARK: - Help

  private func printHelp() {
    print("""
    \(Terminal.bold)Commands:\(Terminal.reset)
      \(Terminal.cyan)quit\(Terminal.reset)       Exit the session
      \(Terminal.cyan)clear\(Terminal.reset)      Clear conversation history
      \(Terminal.cyan)history\(Terminal.reset)    Show token usage stats
      \(Terminal.cyan)help\(Terminal.reset)       Show this help

    \(Terminal.bold)Flags:\(Terminal.reset)
      \(Terminal.cyan)--yolo\(Terminal.reset)     Auto-approve all tool executions
      \(Terminal.cyan)--model\(Terminal.reset)    Choose model (default depends on provider)
      \(Terminal.cyan)--provider\(Terminal.reset) Choose provider: copilot (default) or anthropic

    \(Terminal.bold)Tips:\(Terminal.reset)
      - Just type your request naturally
      - The agent can read/write files, run commands, and use git
      - Destructive operations require confirmation (unless --yolo)
    """)
  }
}

// MARK: - Agent Response

private struct AgentResponse {
  let contentBlocks: [ContentBlock]
  let toolCalls: [(name: String, id: String, input: [String: JSONValue])]
  let inputTokens: Int
  let outputTokens: Int
}
