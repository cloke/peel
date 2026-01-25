//
//  CIFailureFeedbackService.swift
//  Peel
//
//  Captures CI failure patterns from MCP-generated PRs and feeds them back
//  into RAG/prompts to reduce repeated mistakes.
//

import Foundation
import SwiftData
import Github

// MARK: - CI Failure Types

/// Types of CI failures that can be captured
enum CIFailureType: String, CaseIterable, Sendable {
  case build = "build"
  case test = "test"
  case lint = "lint"
  case typecheck = "typecheck"
  case security = "security"
  case other = "other"

  /// Detect failure type from check name
  static func detect(from checkName: String) -> CIFailureType {
    let lowered = checkName.lowercased()

    if lowered.contains("build") || lowered.contains("compile") {
      return .build
    } else if lowered.contains("test") || lowered.contains("spec") || lowered.contains("rspec") {
      return .test
    } else if lowered.contains("lint") || lowered.contains("rubocop") || lowered.contains("eslint") || lowered.contains("swiftlint") {
      return .lint
    } else if lowered.contains("type") || lowered.contains("tsc") || lowered.contains("swift") {
      return .typecheck
    } else if lowered.contains("security") || lowered.contains("snyk") || lowered.contains("dependabot") {
      return .security
    }

    return .other
  }
}

/// Summary of a CI failure pattern
struct CIFailurePatternSummary: Identifiable, Sendable {
  let id: UUID
  let pattern: String
  let failureType: CIFailureType
  let occurrenceCount: Int
  let lastSeen: Date
  let repoPath: String
  let guidance: String?

  init(from record: CIFailureRecord) {
    self.id = record.id
    self.pattern = record.normalizedPattern
    self.failureType = CIFailureType(rawValue: record.failureType) ?? .other
    self.occurrenceCount = record.occurrenceCount
    self.lastSeen = record.lastSeenAt
    self.repoPath = record.repoPath
    self.guidance = record.guidanceGenerated
  }
}

// MARK: - CI Failure Feedback Service

/// Service for capturing and processing CI failures from MCP PRs
@MainActor
@Observable
final class CIFailureFeedbackService {
  private let modelContext: ModelContext

  // Stats
  private(set) var totalFailuresRecorded: Int = 0
  private(set) var uniquePatterns: Int = 0
  private(set) var guidanceGenerated: Int = 0
  private(set) var lastSyncAt: Date?

  // Recent patterns (for UI)
  private(set) var recentPatterns: [CIFailurePatternSummary] = []

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
    Task {
      await loadStats()
    }
  }

  // MARK: - Capture Failures

  /// Capture CI failures from a GitHub workflow run
  func captureFailures(
    from action: Github.Action,
    mcpRunId: UUID,
    repoPath: String,
    prNumber: Int,
    prBranch: String
  ) async {
    // Only process failed runs
    guard action.conclusion == "failure" else { return }

    let checkName = action.name
    let failureType = CIFailureType.detect(from: checkName)
    let failureSummary = buildFailureSummary(from: action)
    let normalizedPattern = normalizePattern(checkName: checkName, summary: failureSummary)

    // Check if pattern already exists
    let descriptor = FetchDescriptor<CIFailureRecord>(
      predicate: #Predicate { record in
        record.repoPath == repoPath && record.normalizedPattern == normalizedPattern
      }
    )

    do {
      let existingRecords = try modelContext.fetch(descriptor)

      if let existing = existingRecords.first {
        // Update existing record
        existing.recordOccurrence()
        existing.failureDetails = failureSummary
      } else {
        // Create new record
        let record = CIFailureRecord(
          mcpRunId: mcpRunId,
          repoPath: repoPath,
          prNumber: prNumber,
          prBranch: prBranch,
          checkName: checkName,
          failureType: failureType.rawValue,
          failureSummary: failureSummary,
          failureDetails: "",
          normalizedPattern: normalizedPattern
        )
        modelContext.insert(record)
      }

      try modelContext.save()
      await loadStats()
    } catch {
      print("CIFailureFeedbackService: Error capturing failure - \(error)")
    }
  }

  /// Capture failure from raw check data
  func captureFailure(
    mcpRunId: UUID,
    repoPath: String,
    prNumber: Int,
    prBranch: String,
    checkName: String,
    conclusion: String,
    output: String?
  ) async {
    guard conclusion == "failure" else { return }

    let failureType = CIFailureType.detect(from: checkName)
    let failureSummary = output ?? "CI check '\(checkName)' failed"
    let normalizedPattern = normalizePattern(checkName: checkName, summary: failureSummary)

    let descriptor = FetchDescriptor<CIFailureRecord>(
      predicate: #Predicate { record in
        record.repoPath == repoPath && record.normalizedPattern == normalizedPattern
      }
    )

    do {
      let existingRecords = try modelContext.fetch(descriptor)

      if let existing = existingRecords.first {
        existing.recordOccurrence()
      } else {
        let record = CIFailureRecord(
          mcpRunId: mcpRunId,
          repoPath: repoPath,
          prNumber: prNumber,
          prBranch: prBranch,
          checkName: checkName,
          failureType: failureType.rawValue,
          failureSummary: failureSummary,
          normalizedPattern: normalizedPattern
        )
        modelContext.insert(record)
      }

      try modelContext.save()
      await loadStats()
    } catch {
      print("CIFailureFeedbackService: Error capturing failure - \(error)")
    }
  }

  // MARK: - Pattern Normalization

  /// Normalize a failure into a deduplicatable pattern
  private func normalizePattern(checkName: String, summary: String) -> String {
    // Extract key components to deduplicate similar failures
    var pattern = checkName.lowercased()
      .replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)

    // Extract error types from summary
    if let errorMatch = extractErrorType(from: summary) {
      pattern += "::\(errorMatch)"
    }

    return pattern
  }

  /// Extract error type/class from failure output
  private func extractErrorType(from output: String) -> String? {
    // Common patterns:
    // - Swift: "error: ..."
    // - Ruby: "NameError:", "NoMethodError:"
    // - JavaScript: "TypeError:", "ReferenceError:"
    // - Build: "undefined reference", "symbol not found"

    let patterns = [
      "\\b(error|Error|ERROR):\\s*([^\\n]+)",
      "\\b(\\w+Error):",
      "\\bundefined reference to\\b",
      "\\bsymbol not found\\b",
      "\\bno method\\b",
      "\\bundefined method\\b",
      "\\bfailed to compile\\b"
    ]

    for pattern in patterns {
      if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
         let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
        if let range = Range(match.range, in: output) {
          return String(output[range]).prefix(50).trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
    }

    return nil
  }

  // MARK: - Build Failure Summary

  private func buildFailureSummary(from action: Github.Action) -> String {
    var summary = "Workflow '\(action.name)' failed"
    if let conclusion = action.conclusion {
      summary += " with conclusion: \(conclusion)"
    }
    summary += " (run #\(action.run_number))"
    return summary
  }

  // MARK: - Guidance Generation

  /// Generate guidance snippets for recent failures
  func generateGuidance(for repoPath: String, limit: Int = 10) async -> [String] {
    var descriptor = FetchDescriptor<CIFailureRecord>(
      predicate: #Predicate<CIFailureRecord> { record in
        record.repoPath == repoPath && record.guidanceGenerated == nil
      },
      sortBy: [SortDescriptor(\.occurrenceCount, order: .reverse)]
    )
    descriptor.fetchLimit = limit

    do {
      let records = try modelContext.fetch(descriptor)
      var guidanceList: [String] = []

      for record in records {
        if let guidance = record.generateGuidance() {
          guidanceList.append(guidance)
          guidanceGenerated += 1
        }
      }

      try modelContext.save()
      return guidanceList
    } catch {
      print("CIFailureFeedbackService: Error generating guidance - \(error)")
      return []
    }
  }

  /// Get top recurring failure patterns for a repo
  func getTopPatterns(for repoPath: String, limit: Int = 5) async -> [CIFailurePatternSummary] {
    var descriptor = FetchDescriptor<CIFailureRecord>(
      predicate: #Predicate<CIFailureRecord> { record in
        record.repoPath == repoPath && !record.isResolved
      },
      sortBy: [SortDescriptor(\.occurrenceCount, order: .reverse)]
    )
    descriptor.fetchLimit = limit

    do {
      let records = try modelContext.fetch(descriptor)
      return records.map { CIFailurePatternSummary(from: $0) }
    } catch {
      print("CIFailureFeedbackService: Error fetching patterns - \(error)")
      return []
    }
  }

  /// Get all unresolved patterns across repos
  func getAllUnresolvedPatterns(limit: Int = 20) async -> [CIFailurePatternSummary] {
    var descriptor = FetchDescriptor<CIFailureRecord>(
      predicate: #Predicate<CIFailureRecord> { record in
        !record.isResolved
      },
      sortBy: [SortDescriptor(\.occurrenceCount, order: .reverse)]
    )
    descriptor.fetchLimit = limit

    do {
      let records = try modelContext.fetch(descriptor)
      return records.map { CIFailurePatternSummary(from: $0) }
    } catch {
      print("CIFailureFeedbackService: Error fetching patterns - \(error)")
      return []
    }
  }

  // MARK: - RAG Integration

  /// Get failure guidance to inject into prompts
  func getPromptGuidance(for repoPath: String) async -> String? {
    let patterns = await getTopPatterns(for: repoPath, limit: 3)

    guard !patterns.isEmpty else { return nil }

    var guidance = "## Recent CI Failure Patterns\n\n"
    guidance += "The following CI failures have been observed in this repository. Avoid these patterns:\n\n"

    for pattern in patterns {
      guidance += "- **\(pattern.pattern)** (\(pattern.failureType.rawValue), seen \(pattern.occurrenceCount)x)\n"
    }

    return guidance
  }

  /// Mark patterns as indexed in RAG
  func markAsIndexedInRAG(patternIds: [UUID]) async {
    let descriptor = FetchDescriptor<CIFailureRecord>(
      predicate: #Predicate { record in
        patternIds.contains(record.id)
      }
    )

    do {
      let records = try modelContext.fetch(descriptor)
      for record in records {
        record.isIndexedInRAG = true
      }
      try modelContext.save()
    } catch {
      print("CIFailureFeedbackService: Error marking as indexed - \(error)")
    }
  }

  /// Resolve a failure pattern (no longer relevant)
  func resolvePattern(id: UUID) async {
    let descriptor = FetchDescriptor<CIFailureRecord>(
      predicate: #Predicate { record in
        record.id == id
      }
    )

    do {
      let records = try modelContext.fetch(descriptor)
      for record in records {
        record.isResolved = true
      }
      try modelContext.save()
      await loadStats()
    } catch {
      print("CIFailureFeedbackService: Error resolving pattern - \(error)")
    }
  }

  // MARK: - Stats

  private func loadStats() async {
    do {
      let allDescriptor = FetchDescriptor<CIFailureRecord>()
      let allRecords = try modelContext.fetch(allDescriptor)

      totalFailuresRecorded = allRecords.reduce(0) { $0 + $1.occurrenceCount }
      uniquePatterns = Set(allRecords.map(\.normalizedPattern)).count
      guidanceGenerated = allRecords.filter { $0.guidanceGenerated != nil }.count

      // Load recent patterns
      var recentDescriptor = FetchDescriptor<CIFailureRecord>(
        predicate: #Predicate<CIFailureRecord> { !$0.isResolved },
        sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
      )
      recentDescriptor.fetchLimit = 10
      let recentRecords = try modelContext.fetch(recentDescriptor)
      recentPatterns = recentRecords.map { CIFailurePatternSummary(from: $0) }

    } catch {
      print("CIFailureFeedbackService: Error loading stats - \(error)")
    }
  }
}
