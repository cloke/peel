//
//  ValidationConfiguration.swift
//  Peel
//
//  Created on 1/18/26.
//

import Foundation

/// Configuration for validation rules
public struct ValidationConfiguration: Codable, Hashable, Sendable {
  public enum RuleType: String, Codable, Sendable {
    case success
    case output
    case reviewerApproval
    case gitDiff
    case heuristic
  }
  
  public let enabledRules: [RuleType]
  
  public init(enabledRules: [RuleType] = []) {
    self.enabledRules = enabledRules
  }
  
  /// Default validation config (all rules)
  public static let `default` = ValidationConfiguration(
    enabledRules: [.success, .output, .reviewerApproval, .heuristic]
  )
  
  /// Strict validation (includes git diff check)
  public static let strict = ValidationConfiguration(
    enabledRules: [.success, .output, .reviewerApproval, .gitDiff, .heuristic]
  )
  
  /// Minimal validation (just success check)
  public static let minimal = ValidationConfiguration(
    enabledRules: [.success]
  )
  
  /// No validation
  public static let none = ValidationConfiguration(
    enabledRules: []
  )
  
  /// Create validation rules from this configuration
  public func createRules() -> [ValidationRule] {
    enabledRules.map { ruleType in
      switch ruleType {
      case .success:
        return SuccessValidationRule()
      case .output:
        return OutputValidationRule()
      case .reviewerApproval:
        return ReviewerApprovalValidationRule()
      case .gitDiff:
        return GitDiffValidationRule()
      case .heuristic:
        return HeuristicValidationRule()
      }
    }
  }
}


