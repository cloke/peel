import Foundation

public enum MCPTemplateValidationError: LocalizedError {
  case missingName
  case noSteps
  case tooManySteps(max: Int)
  case invalidRole(String)
  case invalidModel(String)

  public var errorDescription: String? {
    switch self {
    case .missingName: return "Template name is required"
    case .noSteps: return "Template must contain at least one step"
    case .tooManySteps(let max): return "Template exceeds maximum steps (\(max))"
    case .invalidRole(let r): return "Invalid role: \(r)"
    case .invalidModel(let m): return "Invalid model: \(m)"
    }
  }
}

public struct MCPTemplateValidator {
  static let allowedRoles = ["planner", "implementer", "reviewer"]
  static let maxSteps = 8

  public static func validate(_ template: MCPTemplate) throws {
    if template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw MCPTemplateValidationError.missingName
    }
    if template.steps.isEmpty {
      throw MCPTemplateValidationError.noSteps
    }
    if template.steps.count > maxSteps {
      throw MCPTemplateValidationError.tooManySteps(max: maxSteps)
    }
    for step in template.steps {
      if !allowedRoles.contains(step.role.lowercased()) {
        throw MCPTemplateValidationError.invalidRole(step.role)
      }
      // Model validation: ensure CopilotModel.fromString exists, but avoid importing model types here.
      if step.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw MCPTemplateValidationError.invalidModel(step.model)
      }
    }
  }
}
