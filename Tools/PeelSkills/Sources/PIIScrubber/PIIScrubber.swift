import ArgumentParser
import CryptoKit
import Foundation
import NaturalLanguage
import Yams

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
    let reader = try LineReader(path: input)
    let writer = try OutputWriter(path: output)
    var reportData = AuditReport(startedAt: Date())
    let configData = try ScrubConfig.load(from: config)
    let configErrors = configData.validationErrors()
    if !configErrors.isEmpty {
      let message = (["Invalid config:"] + configErrors.map { "- \($0)" }).joined(separator: "\n")
      throw ValidationError(message)
    }
    let scrubber = Scrubber(seed: seed, maxSamples: maxSamples, config: configData, enableNER: enableNER)

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
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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

private struct ScrubConfig: Codable {
  var version: Int = 1
  var defaults: Defaults?
  var rules: [Rule] = []

  struct Defaults: Codable {
    var action: Action?
    var format: Format?
  }

  struct Rule: Codable {
    var table: String?
    var column: String?
    var action: Action?
    var format: Format?
  }

  enum Action: String, Codable {
    case preserve
    case redact
    case fake
    case drop
  }

  enum Format: String, Codable {
    case email
    case phone
    case ssn
    case creditCard = "credit_card"
    case name
    case address
    case organization
    case generic
  }

  static func load(from path: String?) throws -> ScrubConfig {
    guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ScrubConfig()
    }

    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let rawText = String(decoding: data, as: UTF8.self)
    let ext = url.pathExtension.lowercased()

    if ext == "yaml" || ext == "yml" {
      return try decodeYAML(rawText)
    }
    if ext == "json" {
      return try decodeJSON(data)
    }

    if let jsonConfig = try? decodeJSON(data) {
      return jsonConfig
    }
    return try decodeYAML(rawText)
  }

  private static func decodeJSON(_ data: Data) throws -> ScrubConfig {
    let decoder = JSONDecoder()
    return try decoder.decode(ScrubConfig.self, from: data)
  }

  private static func decodeYAML(_ text: String) throws -> ScrubConfig {
    return try YAMLDecoder().decode(ScrubConfig.self, from: text)
  }

  func validationErrors() -> [String] {
    var errors: [String] = []
    if version != 1 {
      errors.append("Unsupported config version: \(version)")
    }
    for (index, rule) in rules.enumerated() {
      if rule.table == nil && rule.column == nil {
        errors.append("Rule \(index + 1): specify table and/or column")
      }
      if rule.action == .drop && rule.format != nil {
        errors.append("Rule \(index + 1): drop action cannot include format")
      }
    }
    return errors
  }
}

private final class Scrubber {
  private let seed: String
  private let maxSamples: Int
  private let config: ScrubConfig
  private let enableNER: Bool
  private var emailCache: [String: String] = [:]
  private var phoneCache: [String: String] = [:]
  private var ssnCache: [String: String] = [:]
  private var cardCache: [String: String] = [:]
  private var nameCache: [String: String] = [:]
  private var orgCache: [String: String] = [:]
  private var addressCache: [String: String] = [:]

  private var copyContext: CopyContext?

  private struct CopyContext {
    let table: String
    let columns: [String]
  }

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

  init(seed: String, maxSamples: Int, config: ScrubConfig, enableNER: Bool) {
    self.seed = seed
    self.maxSamples = maxSamples
    self.config = config
    self.enableNER = enableNER
  }

  func scrubLine(_ line: String, report: inout AuditReport) -> String {
    if let context = copyContext {
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "\\." {
        copyContext = nil
        return line
      }
      return scrubCopyLine(line, context: context, report: &report)
    }

    if let newContext = parseCopyStart(line) {
      copyContext = newContext
      return line
    }

    var result = line
    result = replaceMatches(in: result, regex: emailRegex, type: "email", report: &report) { match in
      return deterministicReplacement(for: match, cache: &emailCache, type: "email")
    }
    result = replaceMatches(in: result, regex: phoneRegex, type: "phone", report: &report) { match in
      return deterministicReplacement(for: match, cache: &phoneCache, type: "phone")
    }
    result = replaceMatches(in: result, regex: ssnRegex, type: "ssn", report: &report) { match in
      return deterministicReplacement(for: match, cache: &ssnCache, type: "ssn")
    }
    result = replaceMatches(in: result, regex: cardRegex, type: "credit_card", report: &report) { match in
      return deterministicReplacement(for: match, cache: &cardCache, type: "credit_card")
    }
    if enableNER {
      result = replaceNamedEntities(in: result, report: &report)
    }
    return result
  }

  private func parseCopyStart(_ line: String) -> CopyContext? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let upper = trimmed.uppercased()
    if upper.hasPrefix("COPY "), upper.contains(" FROM STDIN") {
      guard let openParen = trimmed.firstIndex(of: "("),
            let closeParen = trimmed.firstIndex(of: ")"),
            openParen < closeParen else {
        return nil
      }
      let tablePart = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<openParen]
      let columnsPart = trimmed[trimmed.index(after: openParen)..<closeParen]
      let table = normalizeIdentifier(String(tablePart))
      let columns = columnsPart
        .split(separator: ",")
        .map { normalizeIdentifier(String($0)) }
      return CopyContext(table: table, columns: columns)
    }

    let pattern = "^COPY\\s+([^\\s]+)\\s*\\(([^\\)]+)\\)\\s+FROM\\s+stdin;"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
    guard let tableRange = Range(match.range(at: 1), in: line),
          let columnsRange = Range(match.range(at: 2), in: line) else { return nil }

    let table = normalizeIdentifier(String(line[tableRange]))
    let columns = String(line[columnsRange])
      .split(separator: ",")
      .map { normalizeIdentifier(String($0)) }
    return CopyContext(table: table, columns: columns)
  }

  private func scrubCopyLine(_ line: String, context: CopyContext, report: inout AuditReport) -> String {
    let trimmed = line.trimmingCharacters(in: .newlines)
    let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
    guard !fields.isEmpty else { return line }

    var updated: [String] = []
    updated.reserveCapacity(fields.count)
    for (index, field) in fields.enumerated() {
      let column = index < context.columns.count ? context.columns[index] : nil
      let original = String(field)
      if original == "\\N" {
        updated.append(original)
        continue
      }

      let scrubbed = scrubField(
        original,
        table: context.table,
        column: column,
        report: &report
      )
      updated.append(scrubbed)
    }
    return updated.joined(separator: "\t") + "\n"
  }

  private func scrubField(
    _ value: String,
    table: String,
    column: String?,
    report: inout AuditReport
  ) -> String {
    let rule = resolveRule(table: table, column: column)
    let action = rule?.action ?? config.defaults?.action
    let format = rule?.format ?? config.defaults?.format

    if action == .preserve { return value }
    if action == .drop {
      report.record(type: "drop", original: value, replacement: "\\N", maxSamples: maxSamples)
      return "\\N"
    }
    if action == .redact {
      let replacement = "<redacted>"
      report.record(type: "redacted", original: value, replacement: replacement, maxSamples: maxSamples)
      return replacement
    }

    if let format {
      return fakeValue(value, format: format, report: &report)
    }

    var scrubbed = value
    scrubbed = replaceMatches(in: scrubbed, regex: emailRegex, type: "email", report: &report) { match in
      return deterministicReplacement(for: match, cache: &emailCache, type: "email")
    }
    scrubbed = replaceMatches(in: scrubbed, regex: phoneRegex, type: "phone", report: &report) { match in
      return deterministicReplacement(for: match, cache: &phoneCache, type: "phone")
    }
    scrubbed = replaceMatches(in: scrubbed, regex: ssnRegex, type: "ssn", report: &report) { match in
      return deterministicReplacement(for: match, cache: &ssnCache, type: "ssn")
    }
    scrubbed = replaceMatches(in: scrubbed, regex: cardRegex, type: "credit_card", report: &report) { match in
      return deterministicReplacement(for: match, cache: &cardCache, type: "credit_card")
    }
    if enableNER {
      scrubbed = replaceNamedEntities(in: scrubbed, report: &report)
    }
    return scrubbed
  }

  private func resolveRule(table: String, column: String?) -> ScrubConfig.Rule? {
    let rules = config.rules
    let sorted = rules.sorted { lhs, rhs in
      ruleSpecificity(lhs) > ruleSpecificity(rhs)
    }
    for rule in sorted {
      if let tablePattern = rule.table, !matchesPattern(tablePattern, value: table) {
        continue
      }
      if let columnPattern = rule.column {
        guard let column, matchesPattern(columnPattern, value: column) else { continue }
      }
      return rule
    }
    return nil
  }

  private func ruleSpecificity(_ rule: ScrubConfig.Rule) -> Int {
    var score = 0
    if rule.table != nil { score += 1 }
    if rule.column != nil { score += 2 }
    return score
  }

  private func matchesPattern(_ pattern: String, value: String) -> Bool {
    if pattern == "*" { return true }
    if pattern.hasPrefix("regex:") {
      let regexPattern = String(pattern.dropFirst(6))
      return (try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]))
        .map { regex in
          let range = NSRange(value.startIndex..<value.endIndex, in: value)
          return regex.firstMatch(in: value, options: [], range: range) != nil
        } ?? false
    }
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
      .replacingOccurrences(of: "\\*", with: ".*")
      .replacingOccurrences(of: "\\?", with: ".")
    let regexPattern = "^" + escaped + "$"
    return (try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]))
      .map { regex in
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
      } ?? false
  }

  private func deterministicReplacement(
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
    case "name":
      replacement = replaceAlphaNumeric(original, salt: "name")
    case "organization":
      replacement = replaceAlphaNumeric(original, salt: "org")
    case "address":
      replacement = replaceAlphaNumeric(original, salt: "address")
    default:
      replacement = original
    }
    cache[original] = replacement
    return replacement
  }

  private func fakeValue(
    _ value: String,
    format: ScrubConfig.Format,
    report: inout AuditReport
  ) -> String {
    let type: String
    let replacementValue: String
    switch format {
    case .email:
      type = "email"
      replacementValue = deterministicReplacement(for: value, cache: &emailCache, type: type)
    case .phone:
      type = "phone"
      replacementValue = deterministicReplacement(for: value, cache: &phoneCache, type: type)
    case .ssn:
      type = "ssn"
      replacementValue = deterministicReplacement(for: value, cache: &ssnCache, type: type)
    case .creditCard:
      type = "credit_card"
      replacementValue = deterministicReplacement(for: value, cache: &cardCache, type: type)
    case .name:
      type = "name"
      replacementValue = deterministicReplacement(for: value, cache: &nameCache, type: type)
    case .organization:
      type = "organization"
      replacementValue = deterministicReplacement(for: value, cache: &orgCache, type: type)
    case .address:
      type = "address"
      replacementValue = deterministicReplacement(for: value, cache: &addressCache, type: type)
    case .generic:
      type = "generic"
      replacementValue = replaceAlphaNumeric(value, salt: "generic")
    }
    report.record(type: type, original: value, replacement: replacementValue, maxSamples: maxSamples)
    return replacementValue
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

  private func replaceNamedEntities(in input: String, report: inout AuditReport) -> String {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = input
    let range = input.startIndex..<input.endIndex
    var output = input
    var matches: [(Range<String.Index>, String, String)] = []

    tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, tokenRange in
      guard let tag else { return true }
      let type: String
      switch tag {
      case .personalName:
        type = "name"
      case .placeName:
        type = "address"
      case .organizationName:
        type = "organization"
      default:
        return true
      }
      let original = String(input[tokenRange])
      matches.append((tokenRange, original, type))
      return true
    }

    guard !matches.isEmpty else { return input }
    for match in matches.reversed() {
      let (tokenRange, original, type) = match
      let replacementValue: String
      switch type {
      case "name":
        replacementValue = deterministicReplacement(for: original, cache: &nameCache, type: type)
      case "organization":
        replacementValue = deterministicReplacement(for: original, cache: &orgCache, type: type)
      case "address":
        replacementValue = deterministicReplacement(for: original, cache: &addressCache, type: type)
      default:
        continue
      }
      report.record(type: type, original: original, replacement: replacementValue, maxSamples: maxSamples)
      output.replaceSubrange(tokenRange, with: replacementValue)
    }

    return output
  }

  private func normalizeIdentifier(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return unquoted
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
