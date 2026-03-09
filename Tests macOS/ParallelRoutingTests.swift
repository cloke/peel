//
//  ParallelRoutingTests.swift
//  Tests macOS
//
//  Tests for the chains.run → parallel worktree routing (Issue #299).
//

import XCTest
import SwiftData
@testable import Peel

@MainActor
final class ParallelRoutingTests: XCTestCase {

  // MARK: - Test 1: sourceChainRunId stored and findable

  func testSourceChainRunIdLookup() {
    // Create a run with a sourceChainRunId and verify findRunBySourceChainRunId works
    let run1 = ParallelWorktreeRun(
      name: "Chain: test-template",
      projectPath: "/tmp/fake-repo",
      baseBranch: "main"
    )
    let chainRunId = UUID()
    run1.sourceChainRunId = chainRunId

    let run2 = ParallelWorktreeRun(
      name: "Unrelated run",
      projectPath: "/tmp/fake-repo",
      baseBranch: "main"
    )
    // run2 has no sourceChainRunId

    // Simulate what findRunBySourceChainRunId does (direct array search)
    let runs = [run1, run2]
    let found = runs.first { $0.sourceChainRunId == chainRunId }
    XCTAssertNotNil(found, "Should find the run by sourceChainRunId")
    XCTAssertEqual(found?.id, run1.id)
    XCTAssertEqual(found?.sourceChainRunId, chainRunId)

    // Should not find a random UUID
    let notFound = runs.first { $0.sourceChainRunId == UUID() }
    XCTAssertNil(notFound, "Should not find a run with a non-matching sourceChainRunId")

    // run2 has nil sourceChainRunId — should not match
    let nilMatch = runs.first { $0.sourceChainRunId == run2.id }
    XCTAssertNil(nilMatch, "Run without sourceChainRunId should not match")
  }

  // MARK: - Test 2: RunStatus → ChainToolStatus translation

  func testParallelRunStatusToChainToolStatusMapping() {
    // Test each RunStatus maps to the expected chain status string
    // This mirrors the logic in parallelRunToChainStatus()

    let statusMappings: [(ParallelWorktreeRun.RunStatus, String)] = [
      (.pending, "queued"),
      (.running, "running"),
      (.awaitingReview, "awaiting_review"),
      (.completed, "completed"),
      (.failed("something broke"), "failed"),
      (.cancelled, "cancelled"),
      (.merging, "merging"),
    ]

    for (runStatus, expectedChainStatus) in statusMappings {
      let run = ParallelWorktreeRun(
        name: "Test",
        projectPath: "/tmp/fake",
        baseBranch: "main"
      )
      run.status = runStatus
      run.sourceChainRunId = UUID()

      // Add an execution so progress calculation works
      let task = WorktreeTask(title: "T", description: "D", prompt: "P")
      let execution = ParallelWorktreeExecution(task: task)
      run.executions.append(execution)

      // Build ChainToolStatus the same way parallelRunToChainStatus does
      let chainStatus = translateRunStatus(run)
      XCTAssertEqual(
        chainStatus.status, expectedChainStatus,
        "RunStatus.\(runStatus.displayName) should map to '\(expectedChainStatus)', got '\(chainStatus.status)'"
      )

      // Verify error message propagation for .failed
      if case .failed(let msg) = runStatus {
        XCTAssertEqual(chainStatus.error, msg, "Failed status should propagate error message")
      }

      // Verify reviewGate set for awaitingReview
      if case .awaitingReview = runStatus {
        XCTAssertNotNil(chainStatus.reviewGate, "awaitingReview should set reviewGate")
      }
    }
  }

  // MARK: - Test 3: listChainRuns includes parallel-routed runs

  func testListChainRunsIncludesParallelRoutedRuns() {
    // Create parallel runs — some with sourceChainRunId, some without
    let chainRunId1 = UUID()
    let chainRunId2 = UUID()

    let parallelRun1 = ParallelWorktreeRun(
      name: "Chain: feature-a",
      projectPath: "/tmp/repo",
      baseBranch: "main"
    )
    parallelRun1.sourceChainRunId = chainRunId1
    parallelRun1.status = .running
    let task1 = WorktreeTask(title: "T1", description: "D1", prompt: "Do feature A")
    parallelRun1.executions.append(ParallelWorktreeExecution(task: task1))

    let parallelRun2 = ParallelWorktreeRun(
      name: "Chain: feature-b",
      projectPath: "/tmp/repo",
      baseBranch: "main"
    )
    parallelRun2.sourceChainRunId = chainRunId2
    parallelRun2.status = .completed

    let manualRun = ParallelWorktreeRun(
      name: "Manual parallel run",
      projectPath: "/tmp/repo",
      baseBranch: "main"
    )
    // No sourceChainRunId — this is a direct parallel.create, not a chains.run

    let allRuns = [parallelRun1, parallelRun2, manualRun]

    // Simulate the filter logic from listChainRuns:
    // Only runs with sourceChainRunId get included in chain listings
    let knownSourceIds = Set<UUID>() // empty — no active/queued/completed chain runs
    let chainRoutedRuns = allRuns.filter { run in
      guard let sourceId = run.sourceChainRunId else { return false }
      return !knownSourceIds.contains(sourceId)
    }

    XCTAssertEqual(chainRoutedRuns.count, 2, "Only runs with sourceChainRunId should appear in chain listing")
    XCTAssertTrue(
      chainRoutedRuns.contains { $0.sourceChainRunId == chainRunId1 },
      "Should include parallelRun1"
    )
    XCTAssertTrue(
      chainRoutedRuns.contains { $0.sourceChainRunId == chainRunId2 },
      "Should include parallelRun2"
    )
    XCTAssertFalse(
      chainRoutedRuns.contains { $0.id == manualRun.id },
      "Manual run (no sourceChainRunId) should NOT appear in chain listing"
    )

    // Verify deduplication: if a chainRunId is already in known runs, skip it
    let knownWithOne = Set([chainRunId1])
    let dedupedRuns = allRuns.filter { run in
      guard let sourceId = run.sourceChainRunId else { return false }
      return !knownWithOne.contains(sourceId)
    }
    XCTAssertEqual(dedupedRuns.count, 1, "Should deduplicate runs already in known set")
    XCTAssertEqual(dedupedRuns.first?.sourceChainRunId, chainRunId2)
  }

  func testChainRunResultsResolvePersistedParallelRunByPublicIdentifiers() throws {
    let schema = Schema([
      MCPRunRecord.self,
      MCPRunResultRecord.self
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: config)
    let dataService = DataService(modelContext: container.mainContext)
    let server = MCPServerService(config: MCPFileConfig())

    server.dataService = dataService

    let publicRunId = UUID()
    let parallelRunId = UUID()
    let agentId = UUID()

    _ = dataService.recordMCPRun(
      recordId: publicRunId,
      chainId: parallelRunId.uuidString,
      templateId: nil,
      templateName: "Quick Task",
      prompt: "Fix the bug",
      workingDirectory: "/tmp/repo",
      success: true,
      errorMessage: nil,
      mergeConflictsCount: 0,
      resultCount: 1
    )
    _ = dataService.recordMCPRunResult(
      chainId: parallelRunId.uuidString,
      agentId: agentId.uuidString,
      agentName: "Implementer",
      model: "gpt-5-mini",
      prompt: "Fix the bug",
      output: "done",
      premiumCost: 0,
      reviewVerdict: nil
    )

    let byRunId = server.chainRunResults(
      runId: publicRunId.uuidString,
      chainId: nil,
      includeOutputs: true
    )
    XCTAssertEqual(byRunId.count, 1)
    XCTAssertEqual(byRunId.first?["runId"] as? String, publicRunId.uuidString)
    XCTAssertEqual(byRunId.first?["chainId"] as? String, parallelRunId.uuidString)

    let runResults = byRunId.first?["results"] as? [[String: Any]]
    XCTAssertEqual(runResults?.count, 1)
    XCTAssertEqual(runResults?.first?["agentId"] as? String, agentId.uuidString)
    XCTAssertEqual(runResults?.first?["output"] as? String, "done")

    let byChainIdField = server.chainRunResults(
      runId: nil,
      chainId: publicRunId.uuidString,
      includeOutputs: false
    )
    XCTAssertEqual(byChainIdField.count, 1)
    XCTAssertEqual(byChainIdField.first?["runId"] as? String, publicRunId.uuidString)
  }

  // MARK: - Helpers

  /// Mirrors the logic from MCPServerService.parallelRunToChainStatus
  private func translateRunStatus(_ run: ParallelWorktreeRun) -> ChainToolStatus {
    let execution = run.executions.first
    let statusString: String
    var errorMessage: String?
    var reviewGate: String?

    switch run.status {
    case .pending:
      statusString = "queued"
    case .running:
      statusString = "running"
    case .awaitingReview:
      statusString = "awaiting_review"
      reviewGate = "Review required"
    case .completed:
      statusString = "completed"
    case .failed(let msg):
      statusString = "failed"
      errorMessage = msg
    case .cancelled:
      statusString = "cancelled"
    case .merging:
      statusString = "merging"
    }

    let progress: Double = {
      guard let execution else { return 0 }
      switch execution.status {
      case .merged, .approved, .awaitingReview, .reviewed: return 1.0
      case .running: return 0.5
      case .creatingWorktree: return 0.1
      default: return 0
      }
    }()

    return ChainToolStatus(
      chainId: run.sourceChainRunId?.uuidString ?? run.id.uuidString,
      status: statusString,
      progress: progress,
      currentStep: execution?.status.isTerminal == true ? 1 : 0,
      totalSteps: 1,
      error: errorMessage,
      reviewGate: reviewGate,
      startedAt: run.startedAt ?? run.createdAt
    )
  }
}
