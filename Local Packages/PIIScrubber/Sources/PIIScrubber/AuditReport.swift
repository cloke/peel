import Foundation

/// Structured audit report capturing PII detection counts and samples.
public struct AuditReport: Codable, Sendable {
  public var startedAt: Date
  public var completedAt: Date?
  public var counts: [String: Int] = [:]
  public var samples: [String: [Sample]] = [:]

  public struct Sample: Codable, Sendable {
    public let original: String
    public let replacement: String

    public init(original: String, replacement: String) {
      self.original = original
      self.replacement = replacement
    }
  }

  public init(startedAt: Date = Date()) {
    self.startedAt = startedAt
  }

  public mutating func record(type: String, original: String, replacement: String, maxSamples: Int) {
    counts[type, default: 0] += 1
    var current = samples[type, default: []]
    if current.count < maxSamples {
      current.append(Sample(original: original, replacement: replacement))
      samples[type] = current
    }
  }

  public func summaryText() -> String {
    let formatter = ISO8601DateFormatter()
    var output = "PII Scrubber Report\n"
    output += "Started: \(formatter.string(from: startedAt))\n"
    if let completedAt {
      output += "Completed: \(formatter.string(from: completedAt))\n"
    }
    output += "\nCounts:\n"
    for key in counts.keys.sorted() {
      output += "- \(key): \(counts[key] ?? 0)\n"
    }
    output += "\nSamples:\n"
    for key in samples.keys.sorted() {
      output += "\n\(key):\n"
      for sample in samples[key] ?? [] {
        output += "  - \(sample.original) -> \(sample.replacement)\n"
      }
    }
    return output
  }
}
