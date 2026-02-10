import Foundation
import Testing
@testable import PIIScrubber

@Suite("PIIScrubber Core Tests")
struct PIIScrubberTests {

  @Test("Email detection and replacement")
  func emailScrubbing() {
    let config = ScrubConfig()
    let scrubber = Scrubber(seed: "test", maxSamples: 5, config: config)
    var report = AuditReport()

    let input = "Contact john.doe@example.com for info\n"
    let result = scrubber.scrubLine(input, report: &report)

    #expect(!result.contains("john.doe@example.com"))
    #expect(result.contains("@"))
    #expect(report.counts["email"] == 1)
  }

  @Test("Phone number detection and replacement")
  func phoneScrubbing() {
    let config = ScrubConfig()
    let scrubber = Scrubber(seed: "test", maxSamples: 5, config: config)
    var report = AuditReport()

    let input = "Call me at 555-123-4567\n"
    let result = scrubber.scrubLine(input, report: &report)

    #expect(!result.contains("555-123-4567"))
    #expect(report.counts["phone"] == 1)
  }

  @Test("SSN detection and replacement")
  func ssnScrubbing() {
    let config = ScrubConfig()
    let scrubber = Scrubber(seed: "test", maxSamples: 5, config: config)
    var report = AuditReport()

    let input = "SSN: 123-45-6789\n"
    let result = scrubber.scrubLine(input, report: &report)

    #expect(!result.contains("123-45-6789"))
    #expect(report.counts["ssn"] == 1)
  }

  @Test("Deterministic replacements with same seed")
  func deterministicReplacements() {
    let config = ScrubConfig()
    let scrubber1 = Scrubber(seed: "same-seed", maxSamples: 5, config: config)
    let scrubber2 = Scrubber(seed: "same-seed", maxSamples: 5, config: config)
    var report1 = AuditReport()
    var report2 = AuditReport()

    let input = "Email: test@example.com\n"
    let result1 = scrubber1.scrubLine(input, report: &report1)
    let result2 = scrubber2.scrubLine(input, report: &report2)

    #expect(result1 == result2)
  }

  @Test("Different seeds produce different output")
  func differentSeeds() {
    let config = ScrubConfig()
    let scrubber1 = Scrubber(seed: "seed-a", maxSamples: 5, config: config)
    let scrubber2 = Scrubber(seed: "seed-b", maxSamples: 5, config: config)
    var report1 = AuditReport()
    var report2 = AuditReport()

    let input = "Email: test@example.com\n"
    let result1 = scrubber1.scrubLine(input, report: &report1)
    let result2 = scrubber2.scrubLine(input, report: &report2)

    #expect(result1 != result2)
  }

  @Test("Config validation catches errors")
  func configValidation() {
    let config = ScrubConfig(
      version: 2,
      rules: [
        ScrubConfig.Rule(action: .drop, format: .email),
      ]
    )
    let errors = config.validationErrors()

    #expect(errors.count == 3) // bad version + missing table/column + drop with format
  }

  @Test("Preserve action passes through unchanged")
  func preserveAction() {
    let config = ScrubConfig(
      defaults: ScrubConfig.Defaults(action: .preserve)
    )
    let scrubber = Scrubber(seed: "test", maxSamples: 5, config: config)
    var report = AuditReport()

    // In COPY context with a preserve-all config, fields should pass through
    let copyLine = "COPY users (id, email) FROM stdin;\n"
    _ = scrubber.scrubLine(copyLine, report: &report)

    let dataLine = "1\tjohn@example.com\n"
    let result = scrubber.scrubLine(dataLine, report: &report)

    #expect(result.contains("john@example.com"))
  }

  @Test("AuditReport summary text")
  func reportSummary() {
    var report = AuditReport()
    report.record(type: "email", original: "a@b.com", replacement: "x@y.com", maxSamples: 5)
    report.record(type: "email", original: "c@d.com", replacement: "z@w.com", maxSamples: 5)

    let text = report.summaryText()
    #expect(text.contains("email: 2"))
    #expect(text.contains("a@b.com -> x@y.com"))
  }

  @Test("ScrubRunner end-to-end")
  func scrubRunnerEndToEnd() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let inputPath = tmpDir.appendingPathComponent("input.txt").path
    let outputPath = tmpDir.appendingPathComponent("output.txt").path

    try "Contact: alice@example.com, phone: 555-867-5309\n"
      .write(toFile: inputPath, atomically: true, encoding: .utf8)

    let runner = ScrubRunner()
    let result = try runner.run(options: .init(
      inputPath: inputPath,
      outputPath: outputPath,
      seed: "test-seed"
    ))

    let output = try String(contentsOfFile: outputPath, encoding: .utf8)
    #expect(!output.contains("alice@example.com"))
    #expect(!output.contains("555-867-5309"))
    #expect(result.report.counts["email"] == 1)
    #expect(result.report.counts["phone"] == 1)
    #expect(result.report.completedAt != nil)

    try fm.removeItem(at: tmpDir)
  }
}
