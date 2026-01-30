//
//  PIIScrubberService.swift
//  Peel
//
//  Extracted from AgentManager.swift on 1/20/26.
//

import Foundation
import TaskRunner

// MARK: - PII Scrubber Report Models

struct PIIScrubberReport: Codable {
  struct Sample: Codable {
    let original: String
    let replacement: String
  }

  var startedAt: Date
  var completedAt: Date?
  var counts: [String: Int]
  var samples: [String: [Sample]]
}

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
    let report: PIIScrubberReport?
  }

  private let executor = ProcessExecutor()
  var isRunning: Bool = false
  var lastError: String?
  var lastResult: ScrubResult?
  private var runningTask: Task<Void, Never>?

  func runScrubber(options: Options) async throws -> ScrubResult {
    let trimmedInput = options.inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedOutput = options.outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInput.isEmpty else { throw ValidationError("Input path is required.") }
    guard !trimmedOutput.isEmpty else { throw ValidationError("Output path is required.") }

    guard let toolPath = resolveToolPath(customPath: options.toolPath) else {
      throw ValidationError("pii-scrubber not found. Build PeelSkills or set a tool path.")
    }

    var arguments: [String] = ["--input", expandPath(trimmedInput), "--output", expandPath(trimmedOutput)]
    if let reportPath = options.reportPath, !reportPath.isEmpty {
      arguments.append(contentsOf: ["--report", expandPath(reportPath)])
    }
    if let reportFormat = options.reportFormat, !reportFormat.isEmpty {
      arguments.append(contentsOf: ["--report-format", reportFormat])
    }
    if let configPath = options.configPath, !configPath.isEmpty {
      arguments.append(contentsOf: ["--config", expandPath(configPath)])
    }
    if let seed = options.seed, !seed.isEmpty {
      arguments.append(contentsOf: ["--seed", seed])
    }
    if let maxSamples = options.maxSamples {
      arguments.append(contentsOf: ["--max-samples", String(maxSamples)])
    }
    if options.enableNER {
      arguments.append("--enable-ner")
    }

    let result = try await executor.execute(toolPath, arguments: arguments, throwOnNonZeroExit: false)
    if result.exitCode != 0 {
      let message = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
      throw ValidationError(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var report: PIIScrubberReport?
    if let reportPath = options.reportPath, !reportPath.isEmpty {
      let path = expandPath(reportPath)
      if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        report = try? decoder.decode(PIIScrubberReport.self, from: data)
      }
    }

    let scrubResult = ScrubResult(
      inputPath: trimmedInput,
      outputPath: trimmedOutput,
      reportPath: options.reportPath,
      report: report
    )
    lastResult = scrubResult
    lastError = nil
    return scrubResult
  }

  func suggestedToolPath() -> String? {
    findToolPath()
  }

  private func resolveToolPath(customPath: String?) -> String? {
    if let customPath, !customPath.isEmpty {
      let expanded = expandPath(customPath)
      if FileManager.default.isExecutableFile(atPath: expanded) {
        return expanded
      }
    }
    return findToolPath()
  }

  private func findToolPath() -> String? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let roots = [
      fm.currentDirectoryPath,
      home,
      URL(fileURLWithPath: home).appendingPathComponent("code").path,
      URL(fileURLWithPath: home).appendingPathComponent("projects").path,
      Bundle.main.bundleURL.deletingLastPathComponent().path
    ]

    var detected: [String] = []
    for root in roots {
      if let ancestor = findAncestor(containing: "Tools/PeelSkills", from: root) {
        detected.append(ancestor)
      }
    }

    for root in Array(Set(detected)) {
      let debugPath = URL(fileURLWithPath: root)
        .appendingPathComponent("Tools/PeelSkills/.build/debug/pii-scrubber")
        .path
      if fm.isExecutableFile(atPath: debugPath) { return debugPath }

      let releasePath = URL(fileURLWithPath: root)
        .appendingPathComponent("Tools/PeelSkills/.build/release/pii-scrubber")
        .path
      if fm.isExecutableFile(atPath: releasePath) { return releasePath }
    }

    return nil
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

  private func findAncestor(containing relativePath: String, from start: String) -> String? {
    var url = URL(fileURLWithPath: start)
    let fm = FileManager.default
    while true {
      let candidate = url.appendingPathComponent(relativePath).path
      if fm.fileExists(atPath: candidate) {
        return url.path
      }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { break }
      url = parent
    }
    return nil
  }
}
