import XCTest
@testable import Peel

@MainActor
final class MissionServiceTests: XCTestCase {

  // MARK: - MissionService Tests

  func testMissionReturnsNilForNonexistentPath() {
    let service = MissionService.shared
    let result = service.mission(for: "/nonexistent/path/to/repo")
    XCTAssertNil(result)
  }

  func testMissionReturnsMissionFromPeelDir() {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("peel-test-\(UUID().uuidString)")
    let peelDir = tmpDir.appendingPathComponent(".peel")
    try? FileManager.default.createDirectory(at: peelDir, withIntermediateDirectories: true)
    let missionFile = peelDir.appendingPathComponent("mission.md")
    try? "Test mission content".write(to: missionFile, atomically: true, encoding: .utf8)

    let result = MissionService.shared.mission(for: tmpDir.path)
    XCTAssertEqual(result, "Test mission content")

    // Cleanup
    MissionService.shared.invalidateCache(for: tmpDir.path)
    try? FileManager.default.removeItem(at: tmpDir)
  }

  func testMissionReturnsNilForEmptyFile() {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("peel-test-\(UUID().uuidString)")
    let peelDir = tmpDir.appendingPathComponent(".peel")
    try? FileManager.default.createDirectory(at: peelDir, withIntermediateDirectories: true)
    let missionFile = peelDir.appendingPathComponent("mission.md")
    try? "   \n  ".write(to: missionFile, atomically: true, encoding: .utf8)

    let result = MissionService.shared.mission(for: tmpDir.path)
    XCTAssertNil(result)

    MissionService.shared.invalidateCache(for: tmpDir.path)
    try? FileManager.default.removeItem(at: tmpDir)
  }

  func testMissionPromptBlockWrapsContent() {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("peel-test-\(UUID().uuidString)")
    let peelDir = tmpDir.appendingPathComponent(".peel")
    try? FileManager.default.createDirectory(at: peelDir, withIntermediateDirectories: true)
    let missionFile = peelDir.appendingPathComponent("mission.md")
    try? "Ship the product".write(to: missionFile, atomically: true, encoding: .utf8)

    let block = MissionService.shared.missionPromptBlock(for: tmpDir.path)
    XCTAssertNotNil(block)
    XCTAssertTrue(block!.contains("## Project Mission"))
    XCTAssertTrue(block!.contains("Ship the product"))

    MissionService.shared.invalidateCache(for: tmpDir.path)
    try? FileManager.default.removeItem(at: tmpDir)
  }

  func testMissionCacheInvalidation() {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("peel-test-\(UUID().uuidString)")
    let peelDir = tmpDir.appendingPathComponent(".peel")
    try? FileManager.default.createDirectory(at: peelDir, withIntermediateDirectories: true)
    let missionFile = peelDir.appendingPathComponent("mission.md")
    try? "Version 1".write(to: missionFile, atomically: true, encoding: .utf8)

    let v1 = MissionService.shared.mission(for: tmpDir.path)
    XCTAssertEqual(v1, "Version 1")

    // Update file, cache should still return v1
    try? "Version 2".write(to: missionFile, atomically: true, encoding: .utf8)
    let cached = MissionService.shared.mission(for: tmpDir.path)
    XCTAssertEqual(cached, "Version 1")

    // Invalidate and re-read
    MissionService.shared.invalidateCache(for: tmpDir.path)
    let v2 = MissionService.shared.mission(for: tmpDir.path)
    XCTAssertEqual(v2, "Version 2")

    MissionService.shared.invalidateCache(for: tmpDir.path)
    try? FileManager.default.removeItem(at: tmpDir)
  }

  // MARK: - ReviewToolsHandler Confidence Tests

  func testConfidenceHighWhenAllPass() async {
    let handler = ReviewToolsHandler()
    let (status, data) = await handler.handle(
      name: "review.confidence",
      id: 1,
      arguments: [
        "buildPassed": true,
        "testsPassed": true,
        "codeQualityScore": 5,
        "securityScore": 5,
        "missionAligned": true,
        "issueCount": 0,
        "criticalIssues": 0,
      ]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    let confidence = result?["confidence"] as? Double ?? 0
    let recommendation = result?["recommendation"] as? String ?? ""

    XCTAssertGreaterThanOrEqual(confidence, 0.85)
    XCTAssertEqual(recommendation, "auto-merge")
  }

  func testConfidenceLowWhenCriticalIssues() async {
    let handler = ReviewToolsHandler()
    let (status, data) = await handler.handle(
      name: "review.confidence",
      id: 2,
      arguments: [
        "buildPassed": false,
        "testsPassed": false,
        "codeQualityScore": 1,
        "securityScore": 1,
        "criticalIssues": 3,
      ]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    let confidence = result?["confidence"] as? Double ?? 1.0
    let recommendation = result?["recommendation"] as? String ?? ""

    XCTAssertLessThan(confidence, 0.6)
    XCTAssertEqual(recommendation, "reject")
  }

  func testConfidenceMediumNeedsHumanReview() async {
    let handler = ReviewToolsHandler()
    let (status, data) = await handler.handle(
      name: "review.confidence",
      id: 3,
      arguments: [
        "buildPassed": true,
        "testsPassed": false,
        "codeQualityScore": 3,
        "securityScore": 3,
        "missionAligned": true,
        "issueCount": 2,
        "criticalIssues": 0,
      ]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    let confidence = result?["confidence"] as? Double ?? 0
    let recommendation = result?["recommendation"] as? String ?? ""

    XCTAssertGreaterThanOrEqual(confidence, 0.6)
    XCTAssertLessThan(confidence, 0.85)
    XCTAssertEqual(recommendation, "human-review")
  }

  // MARK: - MetaToolsHandler Tests

  func testMetaPlanRequiresRepoPath() async {
    let handler = MetaToolsHandler()
    let (status, _) = await handler.handle(
      name: "meta.plan",
      id: 1,
      arguments: [:]
    )
    XCTAssertEqual(status, 400)
  }

  func testMetaPlanReturnsPrompt() async {
    let handler = MetaToolsHandler()
    let (status, data) = await handler.handle(
      name: "meta.plan",
      id: 1,
      arguments: ["repoPath": "/some/repo", "maxTasks": 3]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    let prompt = result?["prompt"] as? String ?? ""

    XCTAssertTrue(prompt.contains("Meta-Agent planner"))
    XCTAssertTrue(prompt.contains("/some/repo"))
    XCTAssertTrue(prompt.contains("3"))
  }

  func testMetaExecuteDryRun() async {
    let handler = MetaToolsHandler()
    let (status, data) = await handler.handle(
      name: "meta.execute",
      id: 1,
      arguments: ["repoPath": "/some/repo", "dryRun": true]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    XCTAssertEqual(result?["dryRun"] as? Bool, true)
    XCTAssertNotNil(result?["loopId"])
  }

  func testMetaStatusListsEmptyLoops() async {
    let handler = MetaToolsHandler()
    let (status, data) = await handler.handle(
      name: "meta.status",
      id: 1,
      arguments: [:]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    XCTAssertEqual(result?["count"] as? Int, 0)
  }

  // MARK: - SprintToolsHandler Tests

  func testSprintStartRequiresRepoPath() async {
    let handler = SprintToolsHandler()
    let (status, _) = await handler.handle(
      name: "sprint.start",
      id: 1,
      arguments: [:]
    )
    XCTAssertEqual(status, 400)
  }

  func testSprintStartReturnsSprint() async {
    let handler = SprintToolsHandler()
    let (status, data) = await handler.handle(
      name: "sprint.start",
      id: 1,
      arguments: ["repoPath": "/test/repo", "maxIterations": 2]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    XCTAssertNotNil(result?["sprintId"])
    XCTAssertEqual(result?["status"] as? String, "running")
  }

  func testSprintStopGraceful() async {
    let handler = SprintToolsHandler()
    // Start a sprint
    let (_, startData) = await handler.handle(
      name: "sprint.start",
      id: 1,
      arguments: ["repoPath": "/test/repo"]
    )
    let startJson = try? JSONSerialization.jsonObject(with: startData) as? [String: Any]
    let sprintId = (startJson?["result"] as? [String: Any])?["sprintId"] as? String ?? ""

    // Stop it gracefully
    let (status, data) = await handler.handle(
      name: "sprint.stop",
      id: 2,
      arguments: ["sprintId": sprintId]
    )
    XCTAssertEqual(status, 200)

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = json?["result"] as? [String: Any]
    XCTAssertEqual(result?["stopRequested"] as? Bool, true)
  }

  func testSprintPreventsDuplicateOnSameRepo() async {
    let handler = SprintToolsHandler()
    // Start first sprint
    let (s1, _) = await handler.handle(
      name: "sprint.start",
      id: 1,
      arguments: ["repoPath": "/test/dup-repo"]
    )
    XCTAssertEqual(s1, 200)

    // Try to start another on same repo
    let (s2, _) = await handler.handle(
      name: "sprint.start",
      id: 2,
      arguments: ["repoPath": "/test/dup-repo"]
    )
    XCTAssertEqual(s2, 409) // Conflict
  }

  // MARK: - ChainTemplate Tests

  func testBuiltInTemplatesNotEmpty() {
    let templates = ChainTemplate.builtInTemplates
    XCTAssertGreaterThan(templates.count, 5)
  }

  func testMetaAgentTemplateExists() {
    let templates = ChainTemplate.builtInTemplates
    let meta = templates.first { $0.name == "Meta-Agent" }
    XCTAssertNotNil(meta)
    XCTAssertTrue(meta!.steps.count >= 4)
    XCTAssertEqual(meta!.category, .specialized)
  }

  func testReviewerAgentTemplateExists() {
    let templates = ChainTemplate.builtInTemplates
    let reviewer = templates.first { $0.name == "Reviewer Agent" }
    XCTAssertNotNil(reviewer)
    XCTAssertTrue(reviewer!.skipReviewGate)
    XCTAssertEqual(reviewer!.completionCriteria, .noValidation)
  }

  func testAllTemplatesHaveUniqueIds() {
    let templates = ChainTemplate.builtInTemplates
    let ids = templates.map(\.id)
    XCTAssertEqual(ids.count, Set(ids).count, "Duplicate template IDs found")
  }

  func testAllTemplatesHaveSteps() {
    let templates = ChainTemplate.builtInTemplates
    for template in templates {
      XCTAssertFalse(template.steps.isEmpty, "Template '\(template.name)' has no steps")
    }
  }

  func testStepTypeCheckpointProperties() {
    let checkpoint = StepType.checkpoint
    XCTAssertEqual(checkpoint.displayName, "Checkpoint")
    XCTAssertFalse(checkpoint.requiresLLM)
    XCTAssertFalse(checkpoint.isAgentic)
  }

  // MARK: - ReviewItemStatus Tests

  func testReviewItemStatusLabels() {
    XCTAssertEqual(ReviewItemStatus.awaitingReview.label, "Pending")
    XCTAssertEqual(ReviewItemStatus.approved.label, "Approved")
    XCTAssertEqual(ReviewItemStatus.rejected.label, "Rejected")
    XCTAssertEqual(ReviewItemStatus.merged.label, "Merged")
    XCTAssertEqual(ReviewItemStatus.readyToMerge.label, "Ready")
  }

  func testReviewFilterAllCases() {
    XCTAssertEqual(ReviewFilter.allCases.count, 5)
    XCTAssertEqual(ReviewFilter.all.label, "All")
    XCTAssertEqual(ReviewFilter.pending.label, "Pending")
  }

  func testReviewSortOrderAllCases() {
    XCTAssertEqual(ReviewSortOrder.allCases.count, 3)
  }

  // MARK: - MissionToolsHandler Tests

  func testMissionGetRequiresRepoPath() async {
    let handler = MissionToolsHandler()
    let (status, _) = await handler.handle(
      name: "mission.get",
      id: 1,
      arguments: [:]
    )
    XCTAssertEqual(status, 400)
  }

  func testMissionCheckRequiresBothParams() async {
    let handler = MissionToolsHandler()
    let (s1, _) = await handler.handle(
      name: "mission.check",
      id: 1,
      arguments: ["repoPath": "/test"]
    )
    XCTAssertEqual(s1, 400) // Missing taskDescription

    let (s2, _) = await handler.handle(
      name: "mission.check",
      id: 2,
      arguments: ["taskDescription": "test"]
    )
    XCTAssertEqual(s2, 400) // Missing repoPath
  }
}
