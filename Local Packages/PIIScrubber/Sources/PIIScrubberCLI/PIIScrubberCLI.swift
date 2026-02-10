import ArgumentParser
import Foundation
import PIIScrubber

@main
struct PIIScrubberCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pii-scrubber",
    abstract: "Stream and scrub PII from text or SQL dumps",
    discussion: """
      Scrubs PII from text streams (e.g. pg_dump) with deterministic replacements.
      Patterns: emails, phone numbers, SSNs, credit cards.

      Example:
        cat dump.sql | pii-scrubber --report scrub-report.json > scrubbed.sql
      """
  )

  @Option(name: .long, help: "Input file path (defaults to stdin)")
  var input: String?

  @Option(name: .long, help: "Output file path (defaults to stdout)")
  var output: String?

  @Option(name: .long, help: "Write audit report to file")
  var report: String?

  @Option(name: .long, help: "Config file path (yaml/json)")
  var config: String?

  @Option(name: .long, help: "Audit report format: json or text")
  var reportFormat: String = "json"

  @Option(name: .long, help: "Deterministic seed for replacements")
  var seed: String = "peel"

  @Option(name: .long, help: "Max samples per PII type in report")
  var maxSamples: Int = 5

  @Flag(name: .long, help: "Enable NER layer (not implemented, regex only)")
  var enableNER: Bool = false

  mutating func run() throws {
    let runner = ScrubRunner()
    let options = ScrubRunner.Options(
      inputPath: input,
      outputPath: output,
      configPath: config,
      seed: seed,
      maxSamples: maxSamples,
      enableNER: enableNER
    )

    let result = try runner.run(options: options)
    try emitReport(result.report)
  }

  private func emitReport(_ reportData: AuditReport) throws {
    guard let report else {
      let summary = reportData.summaryText()
      FileHandle.standardError.write(summary.data(using: .utf8)!)
      return
    }

    let url = URL(fileURLWithPath: report)
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    if reportFormat.lowercased() == "text" {
      try reportData.summaryText().write(to: url, atomically: true, encoding: .utf8)
    } else {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(reportData)
      try data.write(to: url)
    }
  }
}
