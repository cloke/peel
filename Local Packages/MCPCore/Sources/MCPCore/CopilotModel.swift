//
//  CopilotModel.swift
//  MCPCore
//
//  Available AI models for Copilot CLI.
//

import Foundation

/// Available models for Copilot CLI
public enum MCPCopilotModel: String, Codable, CaseIterable, Identifiable, Sendable {
  // Claude models
  case claudeSonnet45 = "claude-sonnet-4.5"
  case claudeHaiku45 = "claude-haiku-4.5"
  case claudeOpus45 = "claude-opus-4.5"
  case claudeSonnet4 = "claude-sonnet-4"

  // GPT models
  case gpt51CodexMax = "gpt-5.1-codex-max"
  case gpt51Codex = "gpt-5.1-codex"
  case gpt52 = "gpt-5.2"
  case gpt51 = "gpt-5.1"
  case gpt5 = "gpt-5"
  case gpt51CodexMini = "gpt-5.1-codex-mini"
  case gpt5Mini = "gpt-5-mini"
  case gpt41 = "gpt-4.1"  // Often free/cheaper

  // Gemini
  case gemini3Pro = "gemini-3-pro-preview"

  public var id: String { rawValue }

  public var displayName: String {
    metadata.displayName
  }

  /// Cost label for UI formatting
  public var costLabel: String {
    premiumCost == 0 ? "Free" : premiumCost.premiumMultiplierString
  }

  /// Display name with premium cost
  public var displayNameWithCost: String {
    "\(displayName) · \(costLabel)"
  }

  /// Premium requests cost per use (0 = free tier)
  public var premiumCost: Double {
    metadata.premiumCost
  }

  /// Whether this is a free-tier model
  public var isFree: Bool {
    premiumCost == 0
  }

  public var shortName: String {
    metadata.shortName
  }

  public var isClaude: Bool {
    metadata.family == .claude
  }

  public var isGPT: Bool {
    metadata.family == .gpt
  }

  public var isGemini: Bool {
    metadata.family == .gemini
  }

  /// Group header for picker
  public var family: String {
    metadata.family.displayName
  }

  public var modelFamily: ModelFamily {
    metadata.family
  }

  public enum ModelFamily: String, CaseIterable, Identifiable, Sendable {
    case claude
    case gpt
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
      switch self {
      case .claude: return "Claude"
      case .gpt: return "GPT"
      case .gemini: return "Gemini"
      }
    }
  }

  private struct Metadata {
    let displayName: String
    let shortName: String
    let premiumCost: Double
    let family: ModelFamily
  }

  private static let metadataMap: [MCPCopilotModel: Metadata] = [
    .claudeSonnet45: Metadata(displayName: "Claude Sonnet 4.5", shortName: "Sonnet 4.5", premiumCost: 1.0, family: .claude),
    .claudeHaiku45: Metadata(displayName: "Claude Haiku 4.5", shortName: "Haiku 4.5", premiumCost: 0.33, family: .claude),
    .claudeOpus45: Metadata(displayName: "Claude Opus 4.5", shortName: "Opus 4.5", premiumCost: 3.0, family: .claude),
    .claudeSonnet4: Metadata(displayName: "Claude Sonnet 4", shortName: "Sonnet 4", premiumCost: 1.0, family: .claude),
    .gpt51CodexMax: Metadata(displayName: "GPT 5.1 Codex Max", shortName: "Codex Max", premiumCost: 1.0, family: .gpt),
    .gpt51Codex: Metadata(displayName: "GPT 5.1 Codex", shortName: "Codex", premiumCost: 1.0, family: .gpt),
    .gpt52: Metadata(displayName: "GPT 5.2", shortName: "5.2", premiumCost: 1.0, family: .gpt),
    .gpt51: Metadata(displayName: "GPT 5.1", shortName: "5.1", premiumCost: 1.0, family: .gpt),
    .gpt5: Metadata(displayName: "GPT 5", shortName: "5", premiumCost: 1.0, family: .gpt),
    .gpt51CodexMini: Metadata(displayName: "GPT 5.1 Codex Mini", shortName: "Codex Mini", premiumCost: 1.0, family: .gpt),
    .gpt5Mini: Metadata(displayName: "GPT 5 Mini", shortName: "5 Mini", premiumCost: 0.0, family: .gpt),
    .gpt41: Metadata(displayName: "GPT 4.1", shortName: "4.1", premiumCost: 0.0, family: .gpt),
    .gemini3Pro: Metadata(displayName: "Gemini 3 Pro", shortName: "Gemini 3", premiumCost: 0.0, family: .gemini)
  ]

  private var metadata: Metadata {
    Self.metadataMap[self] ?? Metadata(
      displayName: rawValue,
      shortName: rawValue,
      premiumCost: 1.0,
      family: .gpt
    )
  }

  public static func fromString(_ value: String) -> MCPCopilotModel? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let direct = MCPCopilotModel(rawValue: normalized) {
      return direct
    }
    return MCPCopilotModel.allCases.first { model in
      model.displayName.lowercased() == normalized || model.shortName.lowercased() == normalized
    }
  }
}

// MARK: - Double Extension for Premium Cost

extension Double {
  /// Format as premium multiplier string (e.g., "1x", "0.33x", "3x")
  public var premiumMultiplierString: String {
    if self == 0 {
      return "Free"
    } else if self == 1 {
      return "1x"
    } else if self < 1 {
      return String(format: "%.2gx", self)
    } else {
      return String(format: "%.0fx", self)
    }
  }

  /// Format as premium cost display
  public var premiumCostDisplay: String {
    if self == 0 {
      return "Free"
    }
    return String(format: "%.2f premium", self)
  }
}
