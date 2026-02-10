import Foundation
import Yams

/// Configuration for PII scrubbing rules, loadable from YAML or JSON.
public struct ScrubConfig: Codable, Sendable {
  public var version: Int = 1
  public var defaults: Defaults?
  public var rules: [Rule] = []

  public init(version: Int = 1, defaults: Defaults? = nil, rules: [Rule] = []) {
    self.version = version
    self.defaults = defaults
    self.rules = rules
  }

  public struct Defaults: Codable, Sendable {
    public var action: Action?
    public var format: Format?

    public init(action: Action? = nil, format: Format? = nil) {
      self.action = action
      self.format = format
    }
  }

  public struct Rule: Codable, Sendable {
    public var table: String?
    public var column: String?
    public var action: Action?
    public var format: Format?

    public init(table: String? = nil, column: String? = nil, action: Action? = nil, format: Format? = nil) {
      self.table = table
      self.column = column
      self.action = action
      self.format = format
    }
  }

  public enum Action: String, Codable, Sendable {
    case preserve
    case redact
    case fake
    case drop
  }

  public enum Format: String, Codable, Sendable {
    case email
    case phone
    case ssn
    case creditCard = "credit_card"
    case name
    case address
    case organization
    case generic
  }

  /// Load configuration from a file path. Returns default config if path is nil.
  public static func load(from path: String?) throws -> ScrubConfig {
    guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ScrubConfig()
    }

    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let rawText = String(decoding: data, as: UTF8.self)
    let ext = url.pathExtension.lowercased()

    if ext == "yaml" || ext == "yml" {
      return try decodeYAML(rawText)
    }
    if ext == "json" {
      return try decodeJSON(data)
    }

    if let jsonConfig = try? decodeJSON(data) {
      return jsonConfig
    }
    return try decodeYAML(rawText)
  }

  private static func decodeJSON(_ data: Data) throws -> ScrubConfig {
    let decoder = JSONDecoder()
    return try decoder.decode(ScrubConfig.self, from: data)
  }

  private static func decodeYAML(_ text: String) throws -> ScrubConfig {
    return try YAMLDecoder().decode(ScrubConfig.self, from: text)
  }

  /// Validate configuration and return any errors found.
  public func validationErrors() -> [String] {
    var errors: [String] = []
    if version != 1 {
      errors.append("Unsupported config version: \(version)")
    }
    for (index, rule) in rules.enumerated() {
      if rule.table == nil && rule.column == nil {
        errors.append("Rule \(index + 1): specify table and/or column")
      }
      if rule.action == .drop && rule.format != nil {
        errors.append("Rule \(index + 1): drop action cannot include format")
      }
    }
    return errors
  }
}
