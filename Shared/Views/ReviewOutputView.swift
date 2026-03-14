import SwiftUI

// MARK: - Parsed Review Model

struct ParsedReview {
  let summary: String
  let riskLevel: String
  let issues: [String]
  let suggestions: [String]
  let ciStatus: String?
  let verdict: Verdict
  let rawOutput: String

  var hasStructuredContent: Bool {
    verdict != .unknown || !issues.isEmpty || !suggestions.isEmpty
  }

  enum Verdict: String {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
    case unknown = "UNKNOWN"

    var displayName: String {
      switch self {
      case .approve: "Approved"
      case .requestChanges: "Changes Requested"
      case .comment: "Comment"
      case .unknown: "Pending Review"
      }
    }

    var systemImage: String {
      switch self {
      case .approve: "checkmark.circle.fill"
      case .requestChanges: "exclamationmark.triangle.fill"
      case .comment: "text.bubble.fill"
      case .unknown: "questionmark.circle"
      }
    }

    var color: Color {
      switch self {
      case .approve: .green
      case .requestChanges: .red
      case .comment: .orange
      case .unknown: .secondary
      }
    }
  }
}

// MARK: - Parse Review Output

func parseReviewOutput(_ output: String) -> ParsedReview {
  if let structured = parseStructuredReviewJSON(output) { return structured }
  return parseFreeformReview(output)
}

private struct ReviewJSONPayload: Decodable {
  let summary: String?
  let riskLevel: String?
  let issues: AnyCodableArray?
  let suggestions: AnyCodableArray?
  let ciStatus: String?
  let verdict: String?
  // Additional fields agents sometimes use
  let risk: String?
  let risk_level: String?

  var resolvedRiskLevel: String? {
    riskLevel ?? risk_level ?? risk
  }
}

/// Wrapper that decodes either [String] or [{...}] into [String]
private struct AnyCodableArray: Decodable {
  let values: [String]
  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var result: [String] = []
    while !container.isAtEnd {
      if let str = try? container.decode(String.self) {
        result.append(str)
      } else if let obj = try? container.decode([String: AnyCodableValue].self) {
        // Extract description/title/message from object
        let desc = obj["description"]?.stringValue
          ?? obj["title"]?.stringValue
          ?? obj["message"]?.stringValue
          ?? obj["text"]?.stringValue
        let severity = obj["severity"]?.stringValue
        if let desc {
          let prefix = severity.map { "[\($0.capitalized)] " } ?? ""
          result.append("\(prefix)\(desc)")
        }
      } else {
        _ = try? container.decode(AnyCodableValue.self) // skip unknown
      }
    }
    values = result
  }
}

private enum AnyCodableValue: Decodable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null

  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let s = try? container.decode(String.self) { self = .string(s) }
    else if let i = try? container.decode(Int.self) { self = .int(i) }
    else if let d = try? container.decode(Double.self) { self = .double(d) }
    else if let b = try? container.decode(Bool.self) { self = .bool(b) }
    else if container.decodeNil() { self = .null }
    else { self = .null }
  }
}

private func parseStructuredReviewJSON(_ output: String) -> ParsedReview? {
  let candidates = reviewJSONCandidates(from: output)
  let decoder = JSONDecoder()
  for candidate in candidates {
    guard let data = candidate.data(using: .utf8),
          let payload = try? decoder.decode(ReviewJSONPayload.self, from: data)
    else { continue }
    // Skip non-review JSON (e.g. {branch, tasks[]} from code change templates)
    guard payload.summary != nil || payload.verdict != nil || payload.issues != nil else { continue }

    var verdict: ParsedReview.Verdict = {
      switch payload.verdict?.uppercased() {
      case "APPROVE": return .approve
      case "REQUEST_CHANGES": return .requestChanges
      case "COMMENT": return .comment
      default: return .unknown
      }
    }()

    // Infer verdict from content when not explicitly provided
    let issues = payload.issues?.values ?? []
    if verdict == .unknown {
      if issues.contains(where: { $0.lowercased().hasPrefix("high") || $0.lowercased().hasPrefix("critical") || $0.lowercased().hasPrefix("[high") || $0.lowercased().hasPrefix("[critical") }) {
        verdict = .requestChanges
      } else if !issues.isEmpty {
        verdict = .comment
      } else {
        verdict = .approve
      }
    }

    return ParsedReview(
      summary: (payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? String(output.prefix(500)),
      riskLevel: (payload.resolvedRiskLevel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
      issues: issues,
      suggestions: payload.suggestions?.values ?? [],
      ciStatus: payload.ciStatus,
      verdict: verdict,
      rawOutput: output
    )
  }
  return nil
}

private func parseFreeformReview(_ output: String) -> ParsedReview {
  var summary = ""
  var riskLevel = "unknown"
  var issues: [String] = []
  var suggestions: [String] = []
  var ciStatus: String?
  var verdict: ParsedReview.Verdict = .unknown
  var currentSection = ""

  for line in output.components(separatedBy: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let lowered = trimmed.lowercased()

    if lowered.contains("verdict:") || lowered.contains("decision:") {
      if lowered.contains("approve") && !lowered.contains("request") { verdict = .approve }
      else if lowered.contains("request_changes") || lowered.contains("request changes") { verdict = .requestChanges }
      else if lowered.contains("comment") { verdict = .comment }
    }
    if lowered.contains("risk:") || lowered.contains("risk level:") {
      if lowered.contains("high") { riskLevel = "high" }
      else if lowered.contains("medium") { riskLevel = "medium" }
      else if lowered.contains("low") { riskLevel = "low" }
    }
    if lowered.contains("ci status:") || lowered.contains("ci:") || lowered.contains("checks:") {
      ciStatus = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
    }
    if lowered.contains("summary") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) { currentSection = "summary"; continue }
    if lowered.contains("issue") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) { currentSection = "issues"; continue }
    if lowered.contains("suggestion") && (trimmed.hasPrefix("#") || trimmed.hasSuffix(":")) { currentSection = "suggestions"; continue }

    if !trimmed.isEmpty {
      let clean = trimmed.replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
      switch currentSection {
      case "summary": summary = summary.isEmpty ? clean : summary + " " + clean
      case "issues": if clean.count > 3 { issues.append(clean) }
      case "suggestions": if clean.count > 3 { suggestions.append(clean) }
      default: break
      }
    }
  }

  if summary.isEmpty { summary = String(output.prefix(500)) }
  return ParsedReview(summary: summary, riskLevel: riskLevel, issues: issues, suggestions: suggestions, ciStatus: ciStatus, verdict: verdict, rawOutput: output)
}

private func reviewJSONCandidates(from output: String) -> [String] {
  var candidates: [String] = []
  // Fenced code blocks (highest priority)
  if let regex = try? NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)\\s*```") {
    let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
    regex.enumerateMatches(in: output, range: nsRange) { match, _, _ in
      if let match, let range = Range(match.range(at: 1), in: output) {
        candidates.append(String(output[range]))
      }
    }
  }
  // Balanced-brace extraction: find JSON objects containing "summary"
  let chars = Array(output.unicodeScalars)
  var i = 0
  while i < chars.count {
    if chars[i] == "{" {
      var depth = 0
      var j = i
      var inString = false
      var escaped = false
      while j < chars.count {
        let c = chars[j]
        if escaped { escaped = false; j += 1; continue }
        if c == "\\" && inString { escaped = true; j += 1; continue }
        if c == "\"" { inString = !inString; j += 1; continue }
        if !inString {
          if c == "{" { depth += 1 }
          else if c == "}" { depth -= 1; if depth == 0 { break } }
        }
        j += 1
      }
      if depth == 0, j < chars.count {
        let startIdx = output.unicodeScalars.index(output.unicodeScalars.startIndex, offsetBy: i)
        let endIdx = output.unicodeScalars.index(output.unicodeScalars.startIndex, offsetBy: j)
        let candidate = String(output.unicodeScalars[startIdx...endIdx])
        if candidate.contains("\"summary\"") {
          candidates.append(candidate)
        }
      }
    }
    i += 1
  }
  return candidates
}

// MARK: - Step Log Extraction

struct StepLogEntry {
  let name: String
  let preview: String
}

func extractStepLog(from output: String) -> [StepLogEntry] {
  var steps: [StepLogEntry] = []
  let lines = output.components(separatedBy: "\n")
  for (i, line) in lines.enumerated() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("●") || trimmed.hasPrefix("•") {
      let name = String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
      var preview = ""
      if i + 1 < lines.count {
        let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
        if nextLine.hasPrefix("└") {
          preview = String(nextLine.dropFirst().trimmingCharacters(in: .whitespaces))
          if preview.count > 120 { preview = String(preview.prefix(120)) + "…" }
        }
      }
      steps.append(StepLogEntry(name: name, preview: preview))
    }
  }
  return steps
}

// MARK: - Review Output View (shared component)

/// The canonical view for rendering parsed agent review output.
/// Used by RunDetailView, AgentReviewSheet, InlineExecutionCard, and anywhere
/// agent/AI output needs formatted display. Edit THIS view to change how
/// reviews look everywhere.
struct ReviewOutputView: View {
  let parsed: ParsedReview
  var compact: Bool = false
  var showRawOutput: Bool = true
  var showStepLog: Bool = true

  @State private var rawExpanded = false
  @State private var stepsExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 10 : 16) {
      // Verdict banner
      verdictBanner

      // Summary
      if !parsed.summary.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          if !compact {
            Text("Summary")
              .font(.subheadline.weight(.semibold))
          }
          Text(parsed.summary)
            .font(compact ? .caption : .callout)
            .lineLimit(compact ? 4 : nil)
            .textSelection(.enabled)
        }
      }

      // Issues
      if !parsed.issues.isEmpty {
        issuesSection
      }

      // Suggestions
      if !parsed.suggestions.isEmpty {
        suggestionsSection
      }

      // Step log
      if showStepLog {
        let steps = extractStepLog(from: parsed.rawOutput)
        if !steps.isEmpty {
          DisclosureGroup("Steps (\(steps.count) tool calls)", isExpanded: $stepsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 6) {
                  Image(systemName: "circle.fill")
                    .font(.system(size: 4))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(step.name)
                      .font(.caption.weight(.medium))
                    if !step.preview.isEmpty {
                      Text(step.preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.caption)
        }
      }

      // Raw output
      if showRawOutput {
        DisclosureGroup("Raw Output", isExpanded: $rawExpanded) {
          Text(parsed.rawOutput)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
      }
    }
  }

  // MARK: - Subviews

  private var verdictBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: parsed.verdict.systemImage)
        .font(compact ? .body : .title2)
        .foregroundStyle(parsed.verdict.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(parsed.verdict.displayName)
          .font(compact ? .callout.weight(.semibold) : .headline)
        if let ci = parsed.ciStatus {
          Text("CI: \(ci)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(parsed.riskLevel.capitalized)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(riskColor.opacity(0.15), in: Capsule())
        .foregroundStyle(riskColor)
    }
    .padding(compact ? 8 : 12)
    .background(parsed.verdict.color.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var issuesSection: some View {
    let maxItems = compact ? 3 : parsed.issues.count
    return VStack(alignment: .leading, spacing: 6) {
      Label("Issues (\(parsed.issues.count))", systemImage: "exclamationmark.triangle")
        .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(.orange)
      ForEach(Array(parsed.issues.prefix(maxItems).enumerated()), id: \.offset) { _, issue in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "circle.fill")
            .font(.system(size: 5))
            .foregroundStyle(.orange)
            .padding(.top, 6)
          Text(issue)
            .font(compact ? .caption2 : .callout)
            .lineLimit(compact ? 2 : nil)
            .textSelection(.enabled)
        }
      }
      if compact, parsed.issues.count > maxItems {
        Text("+ \(parsed.issues.count - maxItems) more")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(compact ? 8 : 12)
    .background(.orange.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10))
  }

  private var suggestionsSection: some View {
    let maxItems = compact ? 2 : parsed.suggestions.count
    return VStack(alignment: .leading, spacing: 6) {
      Label("Suggestions (\(parsed.suggestions.count))", systemImage: "lightbulb")
        .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(.blue)
      ForEach(Array(parsed.suggestions.prefix(maxItems).enumerated()), id: \.offset) { _, suggestion in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "circle.fill")
            .font(.system(size: 5))
            .foregroundStyle(.blue)
            .padding(.top, 6)
          Text(suggestion)
            .font(compact ? .caption2 : .callout)
            .lineLimit(compact ? 2 : nil)
            .textSelection(.enabled)
        }
      }
      if compact, parsed.suggestions.count > maxItems {
        Text("+ \(parsed.suggestions.count - maxItems) more")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(compact ? 8 : 12)
    .background(.blue.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10))
  }

  private var riskColor: Color {
    switch parsed.riskLevel.lowercased() {
    case "high": .red
    case "medium": .orange
    case "low": .green
    default: .secondary
    }
  }
}
