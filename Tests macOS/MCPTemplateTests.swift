import XCTest
@testable import Peel

final class MCPTemplateTests: XCTestCase {
  func testLoadValidate() throws {
    let json = """
    {
      "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "name": "Test Template",
      "description": "A simple planner->implementer",
      "createdAt": "2026-01-01T00:00:00Z",
      "steps": [
        {"role": "planner", "model": "gpt-4.1", "name": "Planner"},
        {"role": "implementer", "model": "gpt-4.1", "name": "Implementer"}
      ]
    }
    """
    let template = try MCPTemplateLoader.load(from: json)
    try MCPTemplateValidator.validate(template)
    XCTAssertEqual(template.name, "Test Template")
    XCTAssertEqual(template.steps.count, 2)
  }

  func testInvalidRoleFailsValidation() throws {
    let json = """
    {
      "id": "B2C3D4E5-F6A7-8901-BCDE-F12345678901",
      "name": "Bad Template",
      "createdAt": "2026-01-01T00:00:00Z",
      "steps": [
        {"role": "unknown", "model": "gpt-4.1"}
      ]
    }
    """
    let template = try MCPTemplateLoader.load(from: json)
    XCTAssertThrowsError(try MCPTemplateValidator.validate(template))
  }

  func testTemplateWithNoSteps() throws {
    let json = """
    {
      "id": "C3D4E5F6-A7B8-9012-CDEF-123456789012",
      "name": "Empty Template",
      "createdAt": "2026-01-01T00:00:00Z",
      "steps": []
    }
    """
    let template = try MCPTemplateLoader.load(from: json)
    XCTAssertEqual(template.steps.count, 0)
  }

  func testTemplateInitWithDefaults() {
    let template = MCPTemplate(name: "Inline Template")
    XCTAssertEqual(template.name, "Inline Template")
    XCTAssertTrue(template.steps.isEmpty)
    XCTAssertNotNil(template.id)
  }
}
