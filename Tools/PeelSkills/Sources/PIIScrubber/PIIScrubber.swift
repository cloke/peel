import ArgumentParser
import CryptoKit
import Foundation

@main
struct PIIScrubber: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pii-scrubber",
    abstract: "Stream and scrub PII from text or SQL dumps",
    discussion: """
      Scrubs PII from text streams (e.g. pg_dump) with deterministic replacements.
      Patterns: emails, phone numbers, SSNs, credit cards.

      Example:
        cat dump.sql | .build/debug/pii-scrubber --report scrub-report.json > scrubbed.sql
      """
  )

  @Option(name: .long, help: "Input file path (defaults to stdin)")
  var input: String?

  @Option(name: .long, help: "Output file path (defaults to stdout)")
  var output: String?

  @Option(name: .long, help: "Write audit report to file")
  var report: String?

  @Option(name: .long, help: "Audit report format: json or text")
  var reportFormat: String = "json"

  @Option(name: .long, help: "Deterministic seed for replacements")
  var seed: String = "peel"

  @Option(name: .long, help: "Max samples per PII type in report")
  var maxSamples: Int = 5

  @Flag(name: .long, help: "Enable NER layer (not implemented, regex only)")
  var enableNER: Bool = false

  mutating func run() throws {
    if enableNER {
      FileHandle.standardError.write("Warning: NER not implemented; using regex-only detection.\n".data(using: .utf8)!)
    }

    let reader = try LineReader(path: input)
    let writer = try OutputWriter(path: output)
    var reportData = AuditReport(startedAt: Date())
    let scrubber = Scrubber(seed: seed, maxSamples: maxSamples)

    for line in reader {
      let scrubbed = scrubber.scrubLine(line, report: &reportData)
      writer.write(scrubbed)
    }

    try writer.close()
    reportData.completedAt = Date()
    try emitReport(reportData)
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
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(reportData)
      try data.write(to: url)
    }
  }
}

private struct AuditReport: Encodable {
  var startedAt: Date
  var completedAt: Date?
  var counts: [String: Int] = [:]
  var samples: [String: [Sample]] = [:]

  struct Sample: Encodable {
    let original: String
    let replacement: String
  }

  mutating func record(type: String, original: String, replacement: String, maxSamples: Int) {
    counts[type, default: 0] += 1
    var current = samples[type, default: []]
    if current.count < maxSamples {
      current.append(Sample(original: original, replacement: replacement))
      samples[type] = current
    }
  }

  func summaryText() -> String {
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

private final class Scrubber {
  private let seed: String
  private let maxSamples: Int
  private var emailCache: [String: String] = [:]
  private var phoneCache: [String: String] = [:]
  private var ssnCache: [String: String] = [:]
  private var cardCache: [String: String] = [:]

  private let emailRegex = try! NSRegularExpression(
    pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
    options: [.caseInsensitive]
  )
  private let phoneRegex = try! NSRegularExpression(
    pattern: "(?:(?:\\+?1[\\s.-]*)?\\(?\\d{3}\\)?[\\s.-]*\\d{3}[\\s.-]*\\d{4})",
    options: []
  )
  private let ssnRegex = try! NSRegularExpression(
    pattern: "\\b\\d{3}-?\\d{2}-?\\d{4}\\b",
    options: []
  )
  private let cardRegex = try! NSRegularExpression(
    pattern: "\\b(?:\\d[ -]*?){13,19}\\b",
    options: []
  )

  init(seed: String, maxSamples: Int) {
    self.seed = seed
    self.maxSamples = maxSamples
  }

  func scrubLine(_ line: String, report: inout AuditReport) -> String {
    var result = line
    result = replaceMatches(in: result, regex: emailRegex, type: "email", report: &report) { match in
      return replacement(for: match, cache: &emailCache, type: "email")
    }
    result = replaceMatches(in: result, regex: phoneRegex, type: "phone", report: &report) { match in
      return replacement(for: match, cache: &phoneCache, type: "phone")
    }
    result = replaceMatches(in: result, regex: ssnRegex, type: "ssn", report: &report) { match in
      return replacement(for: match, cache: &ssnCache, type: "ssn")
    }
    result = replaceMatches(in: result, regex: cardRegex, type: "credit_card", report: &report) { match in
      return replacement(for: match, cache: &cardCache, type: "credit_card")
    }
    return result
  }

  private func replacement(
    for original: String,
    cache: inout [String: String],
    type: String
  ) -> String {
    if let cached = cache[original] {
      return cached
    }
    let replacement: String
    switch type {
    case "email":
      replacement = fakeEmail(from: original)
    case "phone":
      replacement = replaceDigitsPreservingFormat(original)
    case "ssn":
      replacement = replaceDigitsPreservingFormat(original)
    case "credit_card":
      replacement = replaceDigitsPreservingFormat(original)
    default:
      replacement = original
    }
    cache[original] = replacement
    return replacement
  }

  private func replaceMatches(
    in input: String,
    regex: NSRegularExpression,
    type: String,
    report: inout AuditReport,
    replacer: (String) -> String
  ) -> String {
    let nsrange = NSRange(input.startIndex..<input.endIndex, in: input)
    let matches = regex.matches(in: input, options: [], range: nsrange)
    guard !matches.isEmpty else { return input }

    var output = input
    for match in matches.reversed() {
      guard let range = Range(match.range, in: output) else { continue }
      let original = String(output[range])
      let replacement = replacer(original)
      report.record(type: type, original: original, replacement: replacement, maxSamples: maxSamples)
      output.replaceSubrange(range, with: replacement)
    }
    return output
  }

  private func replaceDigitsPreservingFormat(_ value: String) -> String {
    let digits = hashedDigits(for: value, count: value.filter { $0.isNumber }.count)
    var index = digits.startIndex
    var output = ""
    for char in value {
      if char.isNumber {
        output.append(digits[index])
        index = digits.index(after: index)
      } else {
        output.append(char)
      }
    }
    return output
  }

  private func fakeEmail(from value: String) -> String {
    let parts = value.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else { return value }
    let local = String(parts[0])
    let domain = String(parts[1])

    let localReplacement = replaceAlphaNumeric(local, salt: "local")
    let domainReplacement = replaceDomain(domain)
    return "\(localReplacement)@\(domainReplacement)"
  }

  private func replaceAlphaNumeric(_ value: String, salt: String) -> String {
    let hash = hashedString(for: value + salt)
    var output = ""
    var hashIndex = hash.startIndex
    for char in value {
      if char.isLetter {
        output.append(letter(from: hash[hashIndex]))
        hashIndex = hash.index(after: hashIndex)
      } else if char.isNumber {
        output.append(digit(from: hash[hashIndex]))
        hashIndex = hash.index(after: hashIndex)
      } else {
        output.append(char)
      }
    }
    return output
  }

  private func replaceDomain(_ value: String) -> String {
    let hash = hashedString(for: value + "domain")
    var output = ""
    var hashIndex = hash.startIndex
    for char in value {
      if char == "." || char == "-" {
        output.append(char)
      } else if char.isNumber {
        output.append(digit(from: hash[hashIndex]))
        hashIndex = hash.index(after: hashIndex)
      } else {
        output.append(letter(from: hash[hashIndex]).lowercased())
        hashIndex = hash.index(after: hashIndex)
      }
    }
    return output
  }

  private func hashedDigits(for value: String, count: Int) -> String {
    let bytes = hashBytes(for: value)
    var digits: [Character] = []
    digits.reserveCapacity(max(1, count))
    for i in 0..<max(1, count) {
      let byte = bytes[i % bytes.count]
      let digit = Character(String(Int(byte % 10)))
      digits.append(digit)
    }
    return String(digits)
  }

  private func hashBytes(for value: String) -> [UInt8] {
    let data = Data((seed + value).utf8)
    let digest = SHA256.hash(data: data)
    return Array(digest)
  }

  private func hashedString(for value: String) -> String {
    let bytes = hashBytes(for: value)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  private func letter(from hex: Character) -> Character {
    let scalar = String(hex).unicodeScalars.first?.value ?? 97
    let base = Int(scalar) % 26
    return Character(UnicodeScalar(97 + base)!)
  }

  private func digit(from hex: Character) -> Character {
    let scalar = String(hex).unicodeScalars.first?.value ?? 48
    let value = Int(scalar) % 10
    return Character(UnicodeScalar(48 + value)!)
  }
}

private final class LineReader: Sequence, IteratorProtocol {
  private let handle: FileHandle
  private var buffer = Data()
  private var isEOF = false
  private let chunkSize = 64 * 1024

  init(path: String?) throws {
    if let path {
      handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    } else {
      handle = FileHandle.standardInput
    }
  }

  func next() -> String? {
    while true {
      if let range = buffer.firstRange(of: Data([0x0A])) {
        let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return decodeLine(lineData, appendNewline: true)
      }

      if isEOF {
        guard !buffer.isEmpty else { return nil }
        let lineData = buffer
        buffer.removeAll()
        return decodeLine(lineData, appendNewline: false)
      }

      do {
        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
        if chunk.isEmpty {
          isEOF = true
        } else {
          buffer.append(chunk)
        }
      } catch {
        isEOF = true
      }
    }
  }

  private func decodeLine(_ data: Data, appendNewline: Bool) -> String? {
    if var line = String(data: data, encoding: .utf8) {
      if appendNewline { line.append("\n") }
      return line
    }
    if var line = String(data: data, encoding: .isoLatin1) {
      if appendNewline { line.append("\n") }
      return line
    }
    return nil
  }
}

private final class OutputWriter {
  private let handle: FileHandle
  private let shouldClose: Bool

  init(path: String?) throws {
    if let path {
      let url = URL(fileURLWithPath: path)
      let fm = FileManager.default
      fm.createFile(atPath: path, contents: nil)
      handle = try FileHandle(forWritingTo: url)
      shouldClose = true
    } else {
      handle = FileHandle.standardOutput
      shouldClose = false
    }
  }

  func write(_ string: String) {
    if let data = string.data(using: .utf8) {
      handle.write(data)
    }
  }

  func close() throws {
    if shouldClose {
      try handle.close()
    }
  }
}
