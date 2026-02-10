//
//  PIIScrubberService.swift
//  Peel
//
//  Extracted from AgentManager.swift on 1/20/26.
//  Refactored to use PIIScrubber library directly.
//

import Foundation
import PIIScrubber

// MARK: - Type Aliases for backward compatibility

/// App-level alias so existing code referencing `PIIScrubberReport` still compiles.
typealias PIIScrubberReport = AuditReport

// MARK: - PII Scrubber Service

@MainActor
@Observable
final class PIIScrubberService {
  struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? { message }
  }

  struct Options {
    var inputPath: String
    var outputPath: String
    var reportPath: String?
    var reportFormat: String?
    var configPath: String?
    var seed: String?
    var maxSamples: Int?
    var enableNER: Bool
    var toolPath: String?

    init(
      inputPath: String,
      outputPath: String,
      reportPath: String? = nil,
      reportFormat: String? = nil,
      configPath: String? = nil,
      seed: String? = nil,
      maxSamples: Int? = nil,
      enableNER: Bool = false,
      toolPath: String? = nil
    ) {
      self.inputPath = inputPath
      self.outputPath = outputPath
      self.reportPath = reportPath
      self.reportFormat = reportFormat
      self.configPath = configPath
      self.seed = seed
      self.maxSamples = maxSamples
      self.enableNER = enableNER
      self.toolPath = toolPath
    }
  }

  struct ScrubResult {
    let inputPath: String
    let outputPath: String
    let reportPath: String?
    let report: AuditReport?
  }

  var isRunning: Bool = false
  var lastError: String?
  var lastResult: ScrubResult?
  private var runningTask: Task<Void, Never>?

  func runScrubber(options: Options) async throws -> ScrubResult {
    let trimmedInput = options.inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedOutput = options.outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInput.isEmpty else { throw ValidationError("Input path is required.") }
    guard !trimmedOutput.isEmpty else { throw ValidationError("Output path is required.") }

    let expandedInput = expandPath(trimmedInput)
    let expandedOutput = expandPath(trimmedOutput)
    let expandedConfig: String? = {
      guard let configPath = options.configPath, !configPath.isEmpty else { return nil }
      return expandPath(configPath)
    }()

    let runnerOptions = ScrubRunner.Options(
      inputPath: expandedInput,
      outputPath: expandedOutput,
      configPath: expandedConfig,
      seed: options.seed ?? "peel",
      maxSamples: options.maxSamples ?? 5,
      enableNER: options.enableNER
    )

    // Run on a background thread to avoid blocking the main actor
    let result = try await Task.detached {
      let runner = ScrubRunner()
      return try runner.run(options: runnerOptions)
    }.value

    // Write report file if requested
    if let reportPath = options.reportPath, !reportPath.isEmpty {
      let expanded = expandPath(reportPath)
      let url = URL(fileURLWithPath: expanded)
      let fm = FileManager.default
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

      let reportFormat = (options.reportFormat ?? "json").lowercased()
      if reportFormat == "text" {
        try result.report.summaryText().write(to: url, atomically: true, encoding: .utf8)
      } else {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result.report)
        try data.write(to: url)
      }
    }

    let scrubResult = ScrubResult(
      inputPath: trimmedInput,
      outputPath: trimmedOutput,
      reportPath: options.reportPath,
      report: result.report
    )
    lastResult = scrubResult
    lastError = nil
    return scrubResult
  }

  private func expandPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("~") {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return trimmed.replacingOccurrences(of: "~", with: home)
    }
    if trimmed.hasPrefix("/") {
      return trimmed
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(trimmed)
      .path
  }
}
