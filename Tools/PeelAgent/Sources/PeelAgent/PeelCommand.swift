import ArgumentParser
import Foundation
import LLMClient

@main
struct PeelCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "peel",
    abstract: "Peel — an interactive AI coding agent for your terminal",
    version: "0.2.0",
    subcommands: [ChatCommand.self, PromptCommand.self],
    defaultSubcommand: ChatCommand.self
  )

  /// Override the entry point to strip macOS/Xcode debug launch arguments
  /// (e.g. `-NSDocumentRevisionsDebugMode YES`, `-ApplePersistenceIgnoreState YES`)
  /// that ArgumentParser doesn't recognise.
  static func main() async {
    let rawArgs = Array(CommandLine.arguments.dropFirst())
    let cleanArgs = filterMacOSDebugArgs(rawArgs)

    do {
      var command = try parseAsRoot(cleanArgs)
      if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch {
      exit(withError: error)
    }
  }

  /// Remove `-NS*` and `-Apple*` key-value pairs injected by Xcode at launch.
  private static func filterMacOSDebugArgs(_ args: [String]) -> [String] {
    var filtered: [String] = []
    var i = 0
    while i < args.count {
      let arg = args[i]
      if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
        // Skip the flag and its companion value (e.g. "YES")
        i += 2
      } else {
        filtered.append(arg)
        i += 1
      }
    }
    return filtered
  }
}

// MARK: - Shared Options

struct CommonOptions: ParsableArguments {
  @Option(name: .long, help: "Provider: 'copilot' (default, uses GitHub token) or 'anthropic' (uses Claude API key)")
  var provider: String?

  @Option(name: .long, help: "API key or token. For copilot: GitHub token (auto-detected from `gh auth token`). For anthropic: ANTHROPIC_API_KEY.")
  var apiKey: String?

  @Option(name: .long, help: "Model to use. Copilot: claude-sonnet-4.5 (default), claude-sonnet-4.6, claude-haiku-4.5, gpt-4.1, o3-mini, etc. Anthropic: claude-sonnet-4-20250514")
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

  func buildProvider() async throws -> any LLMProvider {
    let kind = resolvedProvider()

    switch kind {
    case .copilot:
      let session = try await CopilotAuth.resolveSession(
        explicitKey: apiKey,
        onWarning: { Terminal.warning($0) }
      )
      let selectedModel = model ?? "claude-sonnet-4.5"
      return CopilotClient(session: session, model: selectedModel)

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
    let provider = try await options.buildProvider()
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
    let provider = try await options.buildProvider()
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
