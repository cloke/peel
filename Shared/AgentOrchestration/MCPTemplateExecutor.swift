import Foundation

#if os(macOS)
import Observation

public struct MCPTemplateExecutor {
  public static func execute(template: MCPTemplate, prompt: String, agentManager: AgentManager, chainRunner: AgentChainRunner, workingDirectory: String?) async throws -> AgentChainRunner.RunSummary {
    // Convert MCPTemplate to ChainTemplate
    let steps = template.steps.map { s in
      AgentStepTemplate(
        role: AgentRole.fromString(s.role) ?? .implementer,
        model: CopilotModel.fromString(s.model) ?? .claudeSonnet45,
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
