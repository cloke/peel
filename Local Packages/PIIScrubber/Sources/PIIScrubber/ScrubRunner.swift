import Foundation

/// High-level entry point that orchestrates scrubbing a file using the `Scrubber` engine.
///
/// Use this for programmatic invocations from the app or tests. The CLI
/// wraps this same function with ArgumentParser flags.
public struct ScrubRunner {
  public struct Options: Sendable {
    public var inputPath: String?
    public var outputPath: String?
    public var configPath: String?
    public var seed: String
    public var maxSamples: Int
    public var enableNER: Bool

    public init(
      inputPath: String? = nil,
      outputPath: String? = nil,
      configPath: String? = nil,
      seed: String = "peel",
      maxSamples: Int = 5,
      enableNER: Bool = false
    ) {
      self.inputPath = inputPath
      self.outputPath = outputPath
      self.configPath = configPath
      self.seed = seed
      self.maxSamples = maxSamples
      self.enableNER = enableNER
    }
  }

  public struct Result: Sendable {
    public let report: AuditReport

    public init(report: AuditReport) {
      self.report = report
    }
  }

  public init() {}

  /// Run the scrubber with the given options.
  ///
  /// - Returns: The completed audit report.
  /// - Throws: If config is invalid, or I/O errors occur.
  public func run(options: Options) throws -> Result {
    let config = try ScrubConfig.load(from: options.configPath)
    let configErrors = config.validationErrors()
    if !configErrors.isEmpty {
      let message = (["Invalid config:"] + configErrors.map { "- \($0)" }).joined(separator: "\n")
      throw ScrubError.invalidConfig(message)
    }

    let reader = try LineReader(path: options.inputPath)
    let writer = try OutputWriter(path: options.outputPath)
    var report = AuditReport(startedAt: Date())
    let scrubber = Scrubber(
      seed: options.seed,
      maxSamples: options.maxSamples,
      config: config,
      enableNER: options.enableNER
    )

    for line in reader {
      let scrubbed = scrubber.scrubLine(line, report: &report)
      writer.write(scrubbed)
    }

    try writer.close()
    report.completedAt = Date()
    return Result(report: report)
  }
}

/// Errors that the scrub runner can produce.
public enum ScrubError: LocalizedError, Sendable {
  case invalidConfig(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfig(let message):
      return message
    }
  }
}
