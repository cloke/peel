//
//  ValidationRule.swift
//  Peel
//
//  Created on 1/18/26.
//

import Foundation

#if os(macOS)

/// Protocol for validation rules that can be run on chain execution results
public protocol ValidationRule: Sendable {
  /// Name of the validation rule
  var name: String { get }
  
  /// Description of what this rule validates
  var description: String { get }
  
  /// Run the validation rule
  func validate(
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult
}

/// Validates that the chain completed without errors
public struct SuccessValidationRule: ValidationRule {
  public let name = "Success"
  public let description = "Checks that the chain completed without errors"
  
  public init() {}
  
  public func validate(
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult {
    if let errorMessage = summary.errorMessage {
      return .failed(reasons: ["Chain failed: \(errorMessage)"])
    }
    
    if !summary.mergeConflicts.isEmpty {
      return .failed(reasons: [
        "Merge conflicts detected in files:",
        summary.mergeConflicts.joined(separator: ", ")
      ])
    }
    
    return .passed(reason: "Chain completed successfully")
  }
}

/// Validates that all agents produced output
public struct OutputValidationRule: ValidationRule {
  public let name = "Output"
  public let description = "Checks that all agents produced output"
  
  public init() {}
  
  public func validate(
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult {
    var issues: [String] = []
    
    for result in summary.results {
      if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("\(result.agentName) produced no output")
      }
    }
    
    if !issues.isEmpty {
      return .failed(reasons: issues)
    }
    
    return .passed(reason: "All agents produced output")
  }
}

/// Validates that reviewer approved the changes (if present)
public struct ReviewerApprovalValidationRule: ValidationRule {
  public let name = "Reviewer Approval"
  public let description = "Checks that the reviewer approved the changes"
  
  public init() {}
  
  public func validate(
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult {
    // Find reviewer results
    let reviewerResults = summary.results.filter { $0.reviewVerdict != nil }
    
    guard !reviewerResults.isEmpty else {
      return .skipped(reason: "No reviewer in chain")
    }
    
    // Check the last reviewer verdict
    guard let lastReview = reviewerResults.last,
          let verdict = lastReview.reviewVerdict else {
      return .warning(reasons: ["Reviewer did not provide a clear verdict"])
    }
    
    switch verdict {
    case .approved:
      return .passed(reason: "Reviewer approved changes")
    case .needsChanges:
      return .warning(reasons: ["Reviewer requested changes but chain completed"])
    case .rejected:
      return .failed(reasons: ["Reviewer rejected changes"])
    }
  }
}

/// Validates that implementers made changes (git diff not empty)
public struct GitDiffValidationRule: ValidationRule {
  public let name = "Git Changes"
  public let description = "Checks that implementers made git changes"
  
  public init() {}
  
  public func validate(
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult {
    guard let workingDir = workingDirectory else {
      return .skipped(reason: "No working directory specified")
    }
    
    // Run git diff to check for changes
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["diff", "--name-only", "HEAD"]
    process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
      try process.run()
      process.waitUntilExit()
      
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""
      
      if process.terminationStatus != 0 {
        return .warning(reasons: ["Could not check git diff: \(output)"])
      }
      
      let changedFiles = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
      
      if changedFiles.isEmpty {
        return .warning(reasons: ["No git changes detected"])
      }
      
      return .passed(reason: "Changes detected in \(changedFiles.count) file(s)")
    } catch {
      return .warning(reasons: ["Could not run git diff: \(error.localizedDescription)"])
    }
  }
}

/// Heuristic validation based on output content
public struct HeuristicValidationRule: ValidationRule {
  public let name = "Heuristic"
  public let description = "Checks for common issues in output"
  
  public init() {}
  
  public func validate(
    chain: AgentChain,
    summary: AgentChainRunner.RunSummary,
    workingDirectory: String?
  ) async -> ValidationResult {
    var warnings: [String] = []
    
    // Check for error messages in output
    for result in summary.results {
      let output = result.output.lowercased()
      
      if output.contains("error:") || output.contains("exception:") {
        warnings.append("\(result.agentName) output contains error messages")
      }
      
      if output.contains("failed") && !output.contains("0 failed") {
        warnings.append("\(result.agentName) output mentions failures")
      }
      
      if output.contains("todo") || output.contains("fixme") {
        warnings.append("\(result.agentName) output contains TODO/FIXME markers")
      }
    }
    
    if !warnings.isEmpty {
      return .warning(reasons: warnings)
    }
    
    return .passed(reason: "No common issues detected in output")
  }
}

#endif
