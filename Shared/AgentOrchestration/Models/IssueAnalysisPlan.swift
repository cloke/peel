//
//  IssueAnalysisPlan.swift
//  KitchenSync
//
//  Created on 1/31/26.
//

import Foundation

/// Structured output from Issue Analyzer template
public struct IssueAnalysisPlan: Codable, Sendable {
  public let issueNumber: Int
  public let issueTitle: String
  public let issueSummary: String
  public let affectedFiles: [AffectedFile]
  public let suggestedApproach: String
  public let estimatedComplexity: Complexity
  public let ragSearchQueries: [String]
  public let delegationReady: Bool
  
  public struct AffectedFile: Codable, Sendable {
    public let path: String
    public let changeType: ChangeType
    public let description: String
    
    public enum ChangeType: String, Codable, Sendable {
      case create, modify, delete
    }
  }
  
  public enum Complexity: String, Codable, Sendable {
    case low, medium, high
  }
}
