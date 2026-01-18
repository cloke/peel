import XCTest
@testable import Peel

final class MCPTemplateTests: XCTestCase {
  func testLoadValidate() throws {
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
  }

  func testInvalidRoleFailsValidation() throws {
    let json = """
    {
      "name": "Bad Template",
      "steps": [
        {"role": "unknown", "model": "gpt-4.1"}
      ]
    }
    """
    let template = try MCPTemplateLoader.load(from: json)
    XCTAssertThrowsError(try MCPTemplateValidator.validate(template))
  }
}
