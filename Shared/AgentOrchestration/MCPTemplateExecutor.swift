import Foundation

#if os(macOS)
import Observation

public struct MCPTemplateExecutor {
  public enum MCPTemplateExecutorError: LocalizedError {
    case invalidRole(String)
    case invalidModel(String)

    public var errorDescription: String? {
      switch self {
      case .invalidRole(let role): return "Invalid role: \(role)"
      case .invalidModel(let model): return "Invalid model: \(model)"
      }
    }
  }

  @MainActor
  public static func execute(template: MCPTemplate, prompt: String, agentManager: AgentManager, chainRunner: AgentChainRunner, workingDirectory: String?) async throws -> AgentChainRunner.RunSummary {
    // Convert MCPTemplate to ChainTemplate
    let steps = try template.steps.map { s in
      guard let role = AgentRole.fromString(s.role) else {
        throw MCPTemplateExecutorError.invalidRole(s.role)
      }
      guard let model = CopilotModel.fromString(s.model) else {
        throw MCPTemplateExecutorError.invalidModel(s.model)
      }
      return AgentStepTemplate(
        role: role,
        model: model,
        name: s.name ?? s.role.capitalized,
        frameworkHint: (s.frameworkHint.flatMap { FrameworkHint(rawValue: $0) }) ?? .auto,
        customInstructions: s.customInstructions
      )
    }
    let chainTemplate = ChainTemplate(name: template.name, description: template.description ?? "", steps: steps, isBuiltIn: false)
    let chain = agentManager.createChainFromTemplate(chainTemplate, workingDirectory: workingDirectory)
    chain.runSource = .mcp
    let summary = await chainRunner.runChain(chain, prompt: prompt)
    return summary
  }
}
#endif
