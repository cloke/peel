import XCTest
@testable import Peel

final class ValidationTests: XCTestCase {
  
  func testValidationResultCreation() {
    let passed = ValidationResult.passed(reason: "All good")
    XCTAssertEqual(passed.status, .passed)
    XCTAssertEqual(passed.reasons, ["All good"])
    
    let failed = ValidationResult.failed(reasons: ["Error 1", "Error 2"])
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(failed.reasons.count, 2)
    
    let warning = ValidationResult.warning(reasons: ["Warning 1"])
    XCTAssertEqual(warning.status, .warning)
    
    let skipped = ValidationResult.skipped(reason: "No validation")
    XCTAssertEqual(skipped.status, .skipped)
  }
  
  func testValidationResultCombine() {
    let passed1 = ValidationResult.passed(reason: "Test 1")
    let passed2 = ValidationResult.passed(reason: "Test 2")
    let combined = ValidationResult.combine([passed1, passed2])
    XCTAssertEqual(combined.status, .passed)
    
    let failed = ValidationResult.failed(reasons: ["Error"])
    let combinedFailed = ValidationResult.combine([passed1, failed])
    XCTAssertEqual(combinedFailed.status, .failed)
    
    let warning = ValidationResult.warning(reasons: ["Warning"])
    let combinedWarning = ValidationResult.combine([passed1, warning])
    XCTAssertEqual(combinedWarning.status, .warning)
  }
  
  func testValidationResultToDictionary() {
    let result = ValidationResult.passed(reason: "Test passed")
    let dict = result.toDictionary()
    
    XCTAssertEqual(dict["status"] as? String, "passed")
    XCTAssertEqual((dict["reasons"] as? [String])?.first, "Test passed")
    XCTAssertNotNil(dict["timestamp"])
  }
  
  func testSuccessValidationRule() async {
    let rule = SuccessValidationRule()
    XCTAssertEqual(rule.name, "Success")
    
    // Create a mock chain and summary
    let chain = AgentChain(name: "Test Chain")
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Complete",
      results: [],
      mergeConflicts: [],
      errorMessage: nil,
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .passed)
  }
  
  func testSuccessValidationRuleWithError() async {
    let rule = SuccessValidationRule()
    let chain = AgentChain(name: "Test Chain")
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Failed",
      results: [],
      mergeConflicts: [],
      errorMessage: "Test error",
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.first?.contains("Test error") ?? false)
  }
  
  func testSuccessValidationRuleWithMergeConflicts() async {
    let rule = SuccessValidationRule()
    let chain = AgentChain(name: "Test Chain")
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Complete",
      results: [],
      mergeConflicts: ["file1.swift", "file2.swift"],
      errorMessage: nil,
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains { $0.contains("Merge conflicts") })
  }
  
  func testOutputValidationRule() async {
    let rule = OutputValidationRule()
    let chain = AgentChain(name: "Test Chain")
    
    // Test with output
    let resultWithOutput = AgentChainResult(
      agentId: UUID(),
      agentName: "Test Agent",
      model: "test-model",
      prompt: "test",
      output: "Some output"
    )
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Complete",
      results: [resultWithOutput],
      mergeConflicts: [],
      errorMessage: nil,
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .passed)
  }
  
  func testOutputValidationRuleWithEmptyOutput() async {
    let rule = OutputValidationRule()
    let chain = AgentChain(name: "Test Chain")
    
    // Test with empty output
    let resultWithNoOutput = AgentChainResult(
      agentId: UUID(),
      agentName: "Test Agent",
      model: "test-model",
      prompt: "test",
      output: ""
    )
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Complete",
      results: [resultWithNoOutput],
      mergeConflicts: [],
      errorMessage: nil,
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .failed)
  }
  
  func testReviewerApprovalValidationRule() async {
    let rule = ReviewerApprovalValidationRule()
    let chain = AgentChain(name: "Test Chain")
    
    // Test with approved verdict
    let approvedResult = AgentChainResult(
      agentId: UUID(),
      agentName: "Reviewer",
      model: "test-model",
      prompt: "test",
      output: "Output",
      reviewVerdict: .approved
    )
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Complete",
      results: [approvedResult],
      mergeConflicts: [],
      errorMessage: nil,
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .passed)
  }
  
  func testReviewerApprovalValidationRuleWithRejection() async {
    let rule = ReviewerApprovalValidationRule()
    let chain = AgentChain(name: "Test Chain")
    
    // Test with rejected verdict
    let rejectedResult = AgentChainResult(
      agentId: UUID(),
      agentName: "Reviewer",
      model: "test-model",
      prompt: "test",
      output: "Output",
      reviewVerdict: .rejected
    )
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Complete",
      results: [rejectedResult],
      mergeConflicts: [],
      errorMessage: nil,
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .failed)
  }
  
  func testReviewerApprovalValidationRuleNoReviewer() async {
    let rule = ReviewerApprovalValidationRule()
    let chain = AgentChain(name: "Test Chain")
    
    // Test with no reviewer
    let implementerResult = AgentChainResult(
      agentId: UUID(),
      agentName: "Implementer",
      model: "test-model",
      prompt: "test",
      output: "Output"
    )
    let summary = AgentChainRunner.RunSummary(
      chainId: chain.id,
      chainName: chain.name,
      stateDescription: "Complete",
      results: [implementerResult],
      mergeConflicts: [],
      errorMessage: nil,
      validationResult: nil
    )
    
    let result = await rule.validate(chain: chain, summary: summary, workingDirectory: nil)
    XCTAssertEqual(result.status, .skipped)
  }
  
  func testValidationConfiguration() {
    let defaultConfig = ValidationConfiguration.default
    XCTAssertTrue(defaultConfig.enabledRules.contains(.success))
    XCTAssertTrue(defaultConfig.enabledRules.contains(.output))
    
    let strictConfig = ValidationConfiguration.strict
    XCTAssertTrue(strictConfig.enabledRules.contains(.gitDiff))
    
    let minimalConfig = ValidationConfiguration.minimal
    XCTAssertEqual(minimalConfig.enabledRules, [.success])
    
    let noneConfig = ValidationConfiguration.none
    XCTAssertTrue(noneConfig.enabledRules.isEmpty)
  }
  
  func testValidationConfigurationCreateRules() {
    let config = ValidationConfiguration(enabledRules: [.success, .output])
    let rules = config.createRules()
    XCTAssertEqual(rules.count, 2)
    XCTAssertTrue(rules[0] is SuccessValidationRule)
    XCTAssertTrue(rules[1] is OutputValidationRule)
  }
}
