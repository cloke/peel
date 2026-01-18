//
//  ValidationResult.swift
//  Peel
//
//  Created on 1/18/26.
//

import Foundation

/// Result of running validation on a chain execution
public struct ValidationResult: Codable, Sendable {
  public enum Status: String, Codable, Sendable {
    case passed
    case failed
    case warning
    case skipped
  }
  
  public let status: Status
  public let reasons: [String]
  public let metadata: [String: String]
  public let timestamp: Date
  
  public init(
    status: Status,
    reasons: [String] = [],
    metadata: [String: String] = [:]
  ) {
    self.status = status
    self.reasons = reasons
    self.metadata = metadata
    self.timestamp = Date()
  }
  
  /// Create a passing validation result
  public static func passed(reason: String? = nil) -> ValidationResult {
    ValidationResult(
      status: .passed,
      reasons: reason.map { [$0] } ?? []
    )
  }
  
  /// Create a failed validation result
  public static func failed(reasons: [String]) -> ValidationResult {
    ValidationResult(status: .failed, reasons: reasons)
  }
  
  /// Create a warning validation result
  public static func warning(reasons: [String]) -> ValidationResult {
    ValidationResult(status: .warning, reasons: reasons)
  }
  
  /// Create a skipped validation result
  public static func skipped(reason: String) -> ValidationResult {
    ValidationResult(status: .skipped, reasons: [reason])
  }
  
  /// Combine multiple validation results into one
  public static func combine(_ results: [ValidationResult]) -> ValidationResult {
    guard !results.isEmpty else {
      return .skipped(reason: "No validation results")
    }
    
    // If any failed, overall is failed
    if results.contains(where: { $0.status == .failed }) {
      let allReasons = results.flatMap { $0.reasons }
      return .failed(reasons: allReasons)
    }
    
    // If any warning, overall is warning
    if results.contains(where: { $0.status == .warning }) {
      let allReasons = results.flatMap { $0.reasons }
      return .warning(reasons: allReasons)
    }
    
    // All passed or skipped
    let allReasons = results.flatMap { $0.reasons }
    return ValidationResult(status: .passed, reasons: allReasons)
  }
}

extension ValidationResult {
  /// Convert to dictionary for MCP response
  public func toDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "status": status.rawValue,
      "reasons": reasons,
      "metadata": metadata,
      "timestamp": ISO8601DateFormatter().string(from: timestamp)
    ]
    return dict
  }
}
