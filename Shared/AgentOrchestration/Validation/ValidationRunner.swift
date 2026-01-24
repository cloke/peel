//
//  ValidationRunner.swift
//  Peel
//
//  Created on 1/18/26.
//

import Foundation

/// Runs validation rules on chain execution results
public actor ValidationRunner {
  
  /// Run validation rules and return combined result
  public func runValidation(
    rules: [ValidationRule],
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult {
    guard !rules.isEmpty else {
      return .skipped(reason: "No validation rules configured")
    }
    
    var results: [ValidationResult] = []
    
    for rule in rules {
      let result = await rule.validate(
        chain: chain,
        summary: summary,
        workingDirectory: workingDirectory
      )
      results.append(result)
    }
    
    return ValidationResult.combine(results)
  }
}


