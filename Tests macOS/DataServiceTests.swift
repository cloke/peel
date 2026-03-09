import XCTest
import SwiftData
import Foundation
@testable import Peel

@MainActor
final class DataServiceTests: XCTestCase {
  
  var modelContainer: ModelContainer!
  var dataService: DataService!
  
  override func setUp() async throws {
    let schema = Schema([
      MCPRunRecord.self,
      MCPRunResultRecord.self,
      DeviceSettings.self
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    modelContainer = try ModelContainer(for: schema, configurations: config)
    dataService = DataService(modelContext: modelContainer.mainContext)
  }
  
  override func tearDown() async throws {
    modelContainer = nil
    dataService = nil
  }
  
  func testMCPRunPersistence() async throws {
    // Record an MCP run
    let record = dataService.recordMCPRun(
      templateId: "test-id",
      templateName: "test-template",
      prompt: "test prompt",
      workingDirectory: "/tmp/test",
      success: true,
      errorMessage: nil,
      mergeConflictsCount: 0,
      resultCount: 5
    )
    
    // Verify the record was created
    XCTAssertNotNil(record)
    XCTAssertEqual(record.templateId, "test-id")
    XCTAssertEqual(record.templateName, "test-template")
    XCTAssertEqual(record.prompt, "test prompt")
    XCTAssertEqual(record.workingDirectory, "/tmp/test")
    XCTAssertTrue(record.success)
    XCTAssertNil(record.errorMessage)
    XCTAssertEqual(record.mergeConflictsCount, 0)
    XCTAssertEqual(record.resultCount, 5)
    
    // Retrieve recent MCP runs
    let recentRuns = dataService.getRecentMCPRuns()
    
    // Verify the record was persisted
    XCTAssertEqual(recentRuns.count, 1)
    XCTAssertEqual(recentRuns.first?.templateId, "test-id")
    XCTAssertEqual(recentRuns.first?.templateName, "test-template")
    XCTAssertEqual(recentRuns.first?.prompt, "test prompt")
    XCTAssertEqual(recentRuns.first?.success, true)
  }

  func testMCPRunHistoryCleanup() async throws {
    let descriptor = FetchDescriptor<MCPRunRecord>()
    let existing = (try? modelContainer.mainContext.fetch(descriptor)) ?? []
    for record in existing {
      modelContainer.mainContext.delete(record)
    }
    try? modelContainer.mainContext.save()

    for index in 1...105 {
      _ = dataService.recordMCPRun(
        templateId: "cleanup-\(index)",
        templateName: "template-\(index)",
        prompt: "prompt-\(index)",
        workingDirectory: nil,
        success: true,
        errorMessage: nil,
        mergeConflictsCount: 0,
        resultCount: 1
      )
      try? await Task.sleep(for: .milliseconds(2))
    }

    let recentRuns = dataService.getRecentMCPRuns(limit: 200)
    XCTAssertEqual(recentRuns.count, 100)
    XCTAssertEqual(recentRuns.first?.templateName, "template-105")
    XCTAssertEqual(recentRuns.last?.templateName, "template-6")
  }

  func testMCPRunPersistenceUsesExplicitRecordID() async throws {
    let runId = UUID()

    _ = dataService.recordMCPRun(
      recordId: runId,
      chainId: "parallel-run-id",
      templateId: "first-template",
      templateName: "Quick Task",
      prompt: "first prompt",
      workingDirectory: "/tmp/one",
      success: true,
      errorMessage: nil,
      mergeConflictsCount: 0,
      resultCount: 1
    )

    _ = dataService.recordMCPRun(
      recordId: runId,
      chainId: "parallel-run-id",
      templateId: "second-template",
      templateName: "Quick Task",
      prompt: "updated prompt",
      workingDirectory: "/tmp/two",
      success: false,
      errorMessage: "failed",
      mergeConflictsCount: 2,
      resultCount: 3
    )

    let recentRuns = dataService.getRecentMCPRuns(limit: 10)

    XCTAssertEqual(recentRuns.count, 1)
    XCTAssertEqual(recentRuns.first?.id, runId)
    XCTAssertEqual(recentRuns.first?.prompt, "updated prompt")
    XCTAssertEqual(recentRuns.first?.workingDirectory, "/tmp/two")
    XCTAssertFalse(recentRuns.first?.success ?? true)
    XCTAssertEqual(recentRuns.first?.errorMessage, "failed")
    XCTAssertEqual(recentRuns.first?.resultCount, 3)
  }
}
