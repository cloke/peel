import Foundation

/// MCP template schema for external agents
public struct MCPTemplate: Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var description: String?
  public var steps: [MCPTemplate.Step]
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    description: String? = nil,
    steps: [MCPTemplate.Step] = []
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.steps = steps
    self.createdAt = Date()
  }

  public struct Step: Codable, Hashable, Sendable {
    public var role: String
    public var model: String
    public var name: String?
    public var frameworkHint: String?
    public var customInstructions: String?

    public init(
      role: String,
      model: String,
      name: String? = nil,
      frameworkHint: String? = nil,
      customInstructions: String? = nil
    ) {
      self.role = role
      self.model = model
      self.name = name
      self.frameworkHint = frameworkHint
      self.customInstructions = customInstructions
    }
  }
}
