import XCTest
@testable import Peel

final class MCPTemplateTests: XCTestCase {
  func testLoadValidateExecute() async throws {
    let json = """
    {
      "name": "Test Template",
      "description": "A simple planner->implementer",
      "steps": [
        {"role": "planner", "model": "gpt-4.1", "name": "Planner"},
        {"role": "implementer", "model": "gpt-4.1", "name": "Implementer"}
      ]
    }
    """
    let template = try MCPTemplateLoader.load(from: json)
    try MCPTemplateValidator.validate(template)
    // Execution requires AgentManager/AgentChainRunner but just ensure conversion succeeds
    #if os(macOS)
    let agentManager = AgentManager()
    let chainRunner = AgentChainRunner(agentManager: agentManager, cliService: CLIService(), sessionTracker: SessionTracker())
    let summary = try await MCPTemplateExecutor.execute(template: template, prompt: "Do nothing", agentManager: agentManager, chainRunner: chainRunner, workingDirectory: nil)
    XCTAssertNotNil(summary)
    #endif
  }
}
