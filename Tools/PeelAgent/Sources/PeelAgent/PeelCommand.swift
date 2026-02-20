import ArgumentParser
import Foundation

@main
struct PeelCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "peel",
    abstract: "Peel — an interactive AI coding agent for your terminal",
    version: "0.2.0",
    subcommands: [ChatCommand.self, PromptCommand.self],
    defaultSubcommand: ChatCommand.self
  )
}

// MARK: - Shared Options

struct CommonOptions: ParsableArguments {
  @Option(name: .long, help: "Provider: 'copilot' (default, uses GitHub token) or 'anthropic' (uses Claude API key)")
  var provider: String?

  @Option(name: .long, help: "API key or token. For copilot: GitHub token (auto-detected from `gh auth token`). For anthropic: ANTHROPIC_API_KEY.")
  var apiKey: String?

  @Option(name: .long, help: "Model to use. Copilot models: gpt-4.1 (default/free), gpt-4.1-mini, gpt-4o, o1, o3-mini. Anthropic: claude-sonnet-4-20250514")
  var model: String?

  @Option(name: .long, help: "Working directory (default: current directory)")
  var directory: String?

  @Flag(name: .long, help: "Auto-approve tool execution without prompting")
  var yolo: Bool = false

  /// Resolves the provider kind, defaulting to copilot
  func resolvedProvider() -> ProviderKind {
    if let p = provider?.lowercased() {
      switch p {
      case "anthropic", "claude": return .anthropic
      case "copilot", "github": return .copilot
      default:
        Terminal.warning("Unknown provider '\(p)', using copilot")
        return .copilot
      }
    }
    // Auto-detect: if ANTHROPIC_API_KEY is set and no GH token, use anthropic
    if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil,
       GitHubTokenHelper.resolveToken() == nil {
      return .anthropic
    }
    return .copilot
  }

  func buildProvider() throws -> any LLMProvider {
    let kind = resolvedProvider()

    switch kind {
    case .copilot:
      let token = apiKey ?? GitHubTokenHelper.resolveToken()
      guard let token, !token.isEmpty else {
        Terminal.error("No GitHub token found. Run 'gh auth login' or set GH_TOKEN/GITHUB_TOKEN")
        throw ExitCode.failure
      }
      let selectedModel = model ?? "gpt-4.1"
      return CopilotClient(token: token, model: selectedModel)

    case .anthropic:
      let key = apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
      guard let key, !key.isEmpty else {
        Terminal.error("No API key found. Set ANTHROPIC_API_KEY or pass --api-key")
        throw ExitCode.failure
      }
      let selectedModel = model ?? "claude-sonnet-4-20250514"
      return ClaudeClient(apiKey: key, model: selectedModel)
    }
  }
}

// MARK: - Interactive Chat (default)

struct ChatCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "chat",
    abstract: "Start an interactive chat session (default)"
  )

  @OptionGroup var options: CommonOptions

  func run() async throws {
    let provider = try options.buildProvider()
    let workDir = options.directory ?? FileManager.default.currentDirectoryPath
    let toolExecutor = ToolExecutor(workingDirectory: workDir)
    let session = AgentSession(
      provider: provider,
      toolExecutor: toolExecutor,
      autoApprove: options.yolo
    )

    let providerKind = options.resolvedProvider()
    Terminal.printBanner()
    Terminal.info("Provider: \(providerKind.displayName)")
    Terminal.info("Model: \(provider.model)")
    Terminal.info("Working directory: \(workDir)")
    Terminal.info("Type your request, or 'quit' to exit.\n")

    await session.runInteractiveLoop()
  }
}

// MARK: - Single prompt (non-interactive)

struct PromptCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prompt",
    abstract: "Send a single prompt and exit"
  )

  @Argument(help: "The prompt to send")
  var text: String

  @OptionGroup var options: CommonOptions

  func run() async throws {
    let provider = try options.buildProvider()
    let workDir = options.directory ?? FileManager.default.currentDirectoryPath
    let toolExecutor = ToolExecutor(workingDirectory: workDir)
    let session = AgentSession(
      provider: provider,
      toolExecutor: toolExecutor,
      autoApprove: options.yolo
    )

    await session.runSinglePrompt(text)
  }
}
