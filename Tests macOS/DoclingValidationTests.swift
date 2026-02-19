//
//  DoclingValidationTests.swift
//  Peel
//
//  Tests for Docling policy validation engine — issue #266
//
//  The validateMarkdown function in DoclingImportView is private, so we
//  replicate its core NSRegularExpression matching logic here directly.
//

import XCTest
@testable import Peel
import SwiftData

#if os(macOS)

/// Result container mirroring PolicyViolationSummary for testing purposes.
struct TestViolation {
  let ruleId: UUID
  let ruleName: String
  let severity: String
  let lineNumber: Int
  let snippet: String
}

/// Standalone validation function that mirrors DoclingImportView.validateMarkdown
/// without requiring a View or ModelContainer.
private func validateMarkdown(content: String, rules: [(id: UUID, name: String, severity: String, pattern: String)]) -> [TestViolation] {
  let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
  var results: [TestViolation] = []
  for rule in rules {
    guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
    for (index, line) in lines.enumerated() {
      let lineString = String(line)
      let range = NSRange(location: 0, length: lineString.utf16.count)
      if regex.firstMatch(in: lineString, options: [], range: range) != nil {
        results.append(TestViolation(
          ruleId: rule.id,
          ruleName: rule.name,
          severity: rule.severity,
          lineNumber: index + 1,
          snippet: lineString.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
      }
    }
  }
  return results
}

@MainActor
final class DoclingValidationTests: XCTestCase {

  // MARK: - Basic Matching

  /// A rule whose pattern matches a line should produce one violation with the correct line number.
  func testSingleRuleMatchProducesViolation() {
    let ruleId = UUID()
    let rules = [(id: ruleId, name: "Forbidden Word", severity: "error", pattern: "forbidden")]
    let content = "This is fine.\nThis contains forbidden text.\nThis is also fine."

    let violations = validateMarkdown(content: content, rules: rules)

    XCTAssertEqual(violations.count, 1)
    XCTAssertEqual(violations[0].ruleId, ruleId)
    XCTAssertEqual(violations[0].lineNumber, 2, "Violation should be on line 2")
    XCTAssertEqual(violations[0].severity, "error")
    XCTAssertTrue(violations[0].snippet.contains("forbidden"))
  }

  /// When a rule pattern does not match any line, no violations should be produced.
  func testNoMatchProducesNoViolations() {
    let rules = [(id: UUID(), name: "Missing Word", severity: "warning", pattern: "doesNotExistAnywhere")]
    let content = "Line one.\nLine two.\nLine three."

    let violations = validateMarkdown(content: content, rules: rules)

    XCTAssertTrue(violations.isEmpty, "No violations expected when pattern doesn't match")
  }

  // MARK: - Multiple Rules

  /// Multiple rules applied to content should each find their own violations independently.
  func testMultipleRulesMultipleMatches() {
    let rule1Id = UUID()
    let rule2Id = UUID()
    let rules = [
      (id: rule1Id, name: "Rule Alpha", severity: "warning", pattern: "alpha"),
      (id: rule2Id, name: "Rule Beta", severity: "critical", pattern: "beta")
    ]
    let content = "alpha line.\nbeta line.\nalpha and beta here."

    let violations = validateMarkdown(content: content, rules: rules)

    let alphaViolations = violations.filter { $0.ruleId == rule1Id }
    let betaViolations = violations.filter { $0.ruleId == rule2Id }

    XCTAssertEqual(alphaViolations.count, 2, "Alpha should match lines 1 and 3")
    XCTAssertEqual(betaViolations.count, 2, "Beta should match lines 2 and 3")
    XCTAssertEqual(violations.count, 4)
  }

  /// A pattern matching multiple lines should report all matching line numbers.
  func testPatternMatchesMultipleLinesAllCaptured() {
    let ruleId = UUID()
    let rules = [(id: ruleId, name: "Repeat", severity: "warning", pattern: "repeat")]
    let content = "repeat this.\nignore this.\nrepeat that.\nalso repeat once more."

    let violations = validateMarkdown(content: content, rules: rules)

    XCTAssertEqual(violations.count, 3)
    let lineNumbers = violations.map { $0.lineNumber }.sorted()
    XCTAssertEqual(lineNumbers, [1, 3, 4])
  }

  // MARK: - Severity Levels

  /// Severity levels (warning, error, critical) should be preserved exactly in results.
  func testSeverityLevelsPreserved() {
    let rules = [
      (id: UUID(), name: "Warn Rule", severity: "warning", pattern: "warn_token"),
      (id: UUID(), name: "Error Rule", severity: "error", pattern: "error_token"),
      (id: UUID(), name: "Critical Rule", severity: "critical", pattern: "critical_token")
    ]
    let content = "line with warn_token.\nline with error_token.\nline with critical_token."

    let violations = validateMarkdown(content: content, rules: rules)

    XCTAssertEqual(violations.count, 3)
    let severities = Set(violations.map { $0.severity })
    XCTAssertTrue(severities.contains("warning"))
    XCTAssertTrue(severities.contains("error"))
    XCTAssertTrue(severities.contains("critical"))

    let warnViolation = violations.first { $0.severity == "warning" }
    XCTAssertNotNil(warnViolation)
    XCTAssertEqual(warnViolation?.lineNumber, 1)
  }

  // MARK: - Edge Cases

  /// Empty content string should produce zero violations regardless of rules.
  func testEmptyContentProducesNoViolations() {
    let rules = [(id: UUID(), name: "Any Rule", severity: "error", pattern: "anything")]
    let violations = validateMarkdown(content: "", rules: rules)
    XCTAssertTrue(violations.isEmpty)
  }

  /// An invalid/malformed regex pattern should be skipped without crashing.
  func testInvalidRegexPatternDoesNotCrash() {
    let rules = [
      (id: UUID(), name: "Bad Regex", severity: "warning", pattern: "[unclosed"),
      (id: UUID(), name: "Good Regex", severity: "error", pattern: "valid")
    ]
    let content = "Line with valid text here."

    // Should not throw or crash
    let violations = validateMarkdown(content: content, rules: rules)

    // Only the valid regex should produce a result
    XCTAssertEqual(violations.count, 1)
    XCTAssertEqual(violations[0].severity, "error")
  }

  // MARK: - PolicyRule SwiftData Model

  /// PolicyRule @Model should be initializable with required fields and default severity.
  func testPolicyRuleModelInit() {
    let companyId = UUID()
    let rule = PolicyRule(
      companyId: companyId,
      name: "Test Rule",
      detail: "Some detail",
      severity: "critical",
      pattern: "\\bfoo\\b"
    )

    XCTAssertEqual(rule.companyId, companyId)
    XCTAssertEqual(rule.name, "Test Rule")
    XCTAssertEqual(rule.severity, "critical")
    XCTAssertEqual(rule.pattern, "\\bfoo\\b")
    XCTAssertTrue(rule.isEnabled)
  }

  /// Default severity for PolicyRule should be "warning".
  func testPolicyRuleDefaultSeverity() {
    let rule = PolicyRule(
      companyId: UUID(),
      name: "Default Severity Rule",
      pattern: "test"
    )
    XCTAssertEqual(rule.severity, "warning", "Default severity should be 'warning'")
  }

  // MARK: - Case Insensitivity

  /// Pattern matching should be case-insensitive per the validation implementation.
  func testPatternMatchingIsCaseInsensitive() {
    let ruleId = UUID()
    let rules = [(id: ruleId, name: "Case Rule", severity: "warning", pattern: "UPPERCASE")]
    let content = "Here is uppercase text.\nHere is Uppercase Text.\nNo match here."

    let violations = validateMarkdown(content: content, rules: rules)

    XCTAssertEqual(violations.count, 2, "Both case variants should match (case-insensitive)")
    let lineNumbers = violations.map { $0.lineNumber }.sorted()
    XCTAssertEqual(lineNumbers, [1, 2])
  }
}

#endif
