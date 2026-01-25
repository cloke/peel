//
//  TranslationValidatorService.swift
//  Peel
//
//  Extracted from AgentManager.swift on 1/20/26.
//

import Foundation
import TaskRunner

// MARK: - Translation Validation Models

struct TranslationReport: Codable {
  var roots: [TranslationRootReport]
}

struct TranslationRootReport: Codable {
  var path: String
  var baseLocale: String
  var locales: [String]
  var files: [FileReport]
}

struct FileReport: Codable {
  var file: String
  var localesMissingFile: [String]
  var missingKeys: [LocaleKeyList]
  var extraKeys: [LocaleKeyList]
  var placeholderMismatches: [PlaceholderMismatch]
  var typeMismatches: [TypeMismatch]
  var suspectTranslations: [SuspectTranslation]
}

struct LocaleKeyList: Codable {
  var locale: String
  var keys: [String]
}

struct PlaceholderMismatch: Codable {
  var key: String
  var locale: String
  var expected: [String]
  var found: [String]
}

struct TypeMismatch: Codable {
  var key: String
  var locale: String
  var expected: ValueKind
  var found: ValueKind
}

struct SuspectTranslation: Codable {
  var key: String
  var locale: String
  var reason: String
  var baseSample: String?
  var localeSample: String?
}

enum ValueKind: String, Codable {
  case string
  case number
  case array
  case object
  case null
  case unknown
}

enum IssueKind: String, CaseIterable {
  case missing
  case extra
  case placeholders
  case types
  case suspects
}

struct TranslationReportSummary: Codable {
  var roots: [TranslationRootSummary]
}

struct TranslationRootSummary: Codable {
  var path: String
  var files: Int
  var missingKeys: Int
  var extraKeys: Int
  var placeholderMismatches: Int
  var typeMismatches: Int
  var suspectTranslations: Int
}

extension TranslationReport {
  func summary() -> TranslationReportSummary {
    let summaries = roots.map { root -> TranslationRootSummary in
      var missingKeys = 0
      var extraKeys = 0
      var placeholderMismatches = 0
      var typeMismatches = 0
      var suspectTranslations = 0

      for file in root.files {
        missingKeys += file.missingKeys.reduce(0) { $0 + $1.keys.count }
        extraKeys += file.extraKeys.reduce(0) { $0 + $1.keys.count }
        placeholderMismatches += file.placeholderMismatches.count
        typeMismatches += file.typeMismatches.count
        suspectTranslations += file.suspectTranslations.count
      }

      return TranslationRootSummary(
        path: root.path,
        files: root.files.count,
        missingKeys: missingKeys,
        extraKeys: extraKeys,
        placeholderMismatches: placeholderMismatches,
        typeMismatches: typeMismatches,
        suspectTranslations: suspectTranslations
      )
    }

    return TranslationReportSummary(roots: summaries)
  }
}

// MARK: - Translation Validator Service

#if os(macOS)
@MainActor
@Observable
final class TranslationValidatorService {
  struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? { message }
  }

  struct Options {
    var root: String
    var translationsPath: String?
    var baseLocale: String?
    var only: String?
    var summary: Bool
    var toolPath: String?
    var useAppleAI: Bool
    var redactSamples: Bool

    init(
      root: String,
      translationsPath: String? = nil,
      baseLocale: String? = nil,
      only: String? = nil,
      summary: Bool = false,
      toolPath: String? = nil,
      useAppleAI: Bool = false,
      redactSamples: Bool = true
    ) {
      self.root = root
      self.translationsPath = translationsPath
      self.baseLocale = baseLocale
      self.only = only
      self.summary = summary
      self.toolPath = toolPath
      self.useAppleAI = useAppleAI
      self.redactSamples = redactSamples
    }
  }

  private let executor = ProcessExecutor()
  private let appleAIService = AppleAIService()

  var isRunning: Bool = false
  var lastReport: TranslationReport?
  var lastSummary: TranslationReportSummary?
  var lastError: String?
  private var runningTask: Task<Void, Never>?
  var appleAIAvailable: Bool { appleAIService.isAvailable }

  func validate(options: Options) async {
    runningTask?.cancel()
    isRunning = true
    lastError = nil

    runningTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isRunning = false
        self.runningTask = nil
      }

      do {
        let report = try await self.runValidator(options: options)
        self.lastReport = report
        self.lastSummary = report.summary()
      } catch is CancellationError {
        self.lastError = "Validation cancelled."
      } catch {
        self.lastError = error.localizedDescription
      }
    }
    await runningTask?.value
  }

  func cancel() {
    runningTask?.cancel()
    runningTask = nil
    isRunning = false
  }

  func runValidator(options: Options) async throws -> TranslationReport {
    if options.useAppleAI, !appleAIService.isAvailable {
      throw ValidationError("Apple AI is not available on this device.")
    }
    let trimmedRoot = options.root.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRoot.isEmpty else {
      throw ValidationError("Root path is required.")
    }

    guard let toolPath = resolveToolPath(customPath: options.toolPath, rootHint: trimmedRoot) else {
      throw ValidationError("translation-validator not found. Build PeelSkills or set a tool path.")
    }

    let expandedRoot = expandPath(trimmedRoot, rootHint: nil)
    var arguments = ["--json", "--root", expandedRoot]
    if let translationsPath = options.translationsPath, !translationsPath.isEmpty {
      let expandedTranslations = expandPath(translationsPath, rootHint: expandedRoot)
      arguments.append(contentsOf: ["--translations-path", expandedTranslations])
    }
    if let baseLocale = options.baseLocale, !baseLocale.isEmpty {
      arguments.append(contentsOf: ["--base-locale", baseLocale])
    }
    if let only = options.only, !only.isEmpty {
      arguments.append(contentsOf: ["--only", only])
    }
    if options.summary {
      arguments.append("--summary")
    }

    let result = try await executor.execute(toolPath, arguments: arguments, throwOnNonZeroExit: false)
    if result.exitCode != 0 {
      let message = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
      throw ValidationError(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let data = Data(result.stdoutString.utf8)
    var report = try JSONDecoder().decode(TranslationReport.self, from: data)
    if options.useAppleAI {
      report = try await applyAppleAIValidation(to: report, redactSamples: options.redactSamples)
    }
    return report
  }

  func suggestedToolPath(rootHint: String?) -> String? {
    findToolPath(rootHint: rootHint)
  }

  private func resolveToolPath(customPath: String?, rootHint: String?) -> String? {
    if let customPath, !customPath.isEmpty {
      let expanded = expandPath(customPath, rootHint: rootHint)
      if FileManager.default.isExecutableFile(atPath: expanded) {
        return expanded
      }
    }

    return findToolPath(rootHint: rootHint)
  }

  private func findToolPath(rootHint: String?) -> String? {
    let candidates = toolSearchRoots(rootHint: rootHint)
    for root in candidates {
      let debugPath = URL(fileURLWithPath: root)
        .appendingPathComponent("Tools/PeelSkills/.build/debug/translation-validator")
        .path
      if FileManager.default.isExecutableFile(atPath: debugPath) {
        return debugPath
      }

      let releasePath = URL(fileURLWithPath: root)
        .appendingPathComponent("Tools/PeelSkills/.build/release/translation-validator")
        .path
      if FileManager.default.isExecutableFile(atPath: releasePath) {
        return releasePath
      }
    }

    return nil
  }

  private func toolSearchRoots(rootHint: String?) -> [String] {
    var roots: [String] = []
    let fm = FileManager.default

    if let rootHint, !rootHint.isEmpty {
      roots.append(expandPath(rootHint, rootHint: nil))
    }

    roots.append(fm.currentDirectoryPath)

    if let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().path as String? {
      roots.append(bundleParent)
    }

    let home = fm.homeDirectoryForCurrentUser.path
    let commonRoots = [
      home,
      URL(fileURLWithPath: home).appendingPathComponent("code").path,
      URL(fileURLWithPath: home).appendingPathComponent("projects").path
    ]

    roots.append(contentsOf: commonRoots)

    var detected: [String] = []
    for root in roots {
      if let ancestor = findAncestor(containing: "Tools/PeelSkills", from: root) {
        detected.append(ancestor)
      }
    }

    for commonRoot in commonRoots {
      if let children = try? fm.contentsOfDirectory(atPath: commonRoot) {
        for child in children {
          let childPath = URL(fileURLWithPath: commonRoot).appendingPathComponent(child).path
          if let ancestor = findAncestor(containing: "Tools/PeelSkills", from: childPath) {
            detected.append(ancestor)
          }
        }
      }
    }

    return Array(Set(detected))
  }

  private func expandPath(_ path: String, rootHint: String?) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("~") {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return trimmed.replacingOccurrences(of: "~", with: home)
    }
    if trimmed.hasPrefix("/") {
      return trimmed
    }
    if let rootHint, !rootHint.isEmpty {
      return URL(fileURLWithPath: rootHint).appendingPathComponent(trimmed).path
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

  private struct AppleAISuspectResponse: Codable {
    var verdict: String
    var reason: String
  }

  private func applyAppleAIValidation(
    to report: TranslationReport,
    redactSamples: Bool
  ) async throws -> TranslationReport {
    var updatedReport = report
    let maxChecks = 200
    var checksPerformed = 0

    for rootIndex in updatedReport.roots.indices {
      for fileIndex in updatedReport.roots[rootIndex].files.indices {
        let suspects = updatedReport.roots[rootIndex].files[fileIndex].suspectTranslations
        guard !suspects.isEmpty else { continue }

        var revised: [SuspectTranslation] = []
        revised.reserveCapacity(suspects.count)

        for suspect in suspects {
          try Task.checkCancellation()
          if checksPerformed >= maxChecks {
            revised.append(suspect)
            continue
          }

          guard let baseSample = suspect.baseSample,
                let localeSample = suspect.localeSample else {
            revised.append(suspect)
            continue
          }

          do {
            let response = try await evaluateSuspect(
              key: suspect.key,
              locale: suspect.locale,
              baseSample: baseSample,
              localeSample: localeSample,
              redactSamples: redactSamples
            )

            if response.verdict.lowercased() == "ok" {
              checksPerformed += 1
              continue
            }

            var updated = suspect
            if !response.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              updated.reason = response.reason
            }
            revised.append(updated)
            checksPerformed += 1
          } catch {
            var updated = suspect
            updated.reason = "Apple AI skipped: \(error.localizedDescription)"
            revised.append(updated)
            checksPerformed += 1
          }
        }

        updatedReport.roots[rootIndex].files[fileIndex].suspectTranslations = revised
      }
    }

    return updatedReport
  }

  private func evaluateSuspect(
    key: String,
    locale: String,
    baseSample: String,
    localeSample: String,
    redactSamples: Bool
  ) async throws -> AppleAISuspectResponse {
    let sanitizedBase = redactSamples ? TextSanitizer.sanitizeForPrompt(baseSample) : baseSample
    let sanitizedLocale = redactSamples ? TextSanitizer.sanitizeForPrompt(localeSample) : localeSample
    let instructions = "You are a localization QA expert. Return only strict JSON. No extra text."
    let prompt = """
    Determine if this translation is acceptable for the target locale.
    If the translation is identical to the English source, only mark OK when it is a proper noun, brand, or a commonly untranslated term.

    Output JSON only with this schema:
    {"verdict":"ok"|"suspect","reason":"short explanation"}

    Key: \(key)
    Locale: \(locale)
    English: \(sanitizedBase)
    Translation: \(sanitizedLocale)
    """

    let response = try await appleAIService.respond(to: prompt, instructions: instructions)
    if let parsed = parseAppleAISuspectResponse(from: response) {
      return parsed
    }

    let fallbackReason = "Apple AI response could not be parsed."
    return AppleAISuspectResponse(verdict: "suspect", reason: fallbackReason)
  }

  private func parseAppleAISuspectResponse(from text: String) -> AppleAISuspectResponse? {
    if let jsonText = extractJSONObject(from: text),
       let data = jsonText.data(using: .utf8),
       let parsed = try? JSONDecoder().decode(AppleAISuspectResponse.self, from: data) {
      return parsed
    }

    let lower = text.lowercased()
    if lower.contains("verdict") {
      if lower.contains("\"ok\"") || lower.contains(" ok ") || lower.contains("acceptable") {
        return AppleAISuspectResponse(verdict: "ok", reason: "Accepted by Apple AI.")
      }
      if lower.contains("\"suspect\"") || lower.contains("suspect") || lower.contains("problem") {
        return AppleAISuspectResponse(verdict: "suspect", reason: "Flagged by Apple AI.")
      }
    }

    if lower.contains("ok") || lower.contains("acceptable") {
      return AppleAISuspectResponse(verdict: "ok", reason: "Accepted by Apple AI.")
    }
    if lower.contains("suspect") || lower.contains("issue") || lower.contains("incorrect") {
      return AppleAISuspectResponse(verdict: "suspect", reason: "Flagged by Apple AI.")
    }

    return nil
  }

  private func extractJSONObject(from text: String) -> String? {
    guard let start = text.firstIndex(of: "{"),
          let end = text.lastIndex(of: "}") else { return nil }
    guard end > start else { return nil }
    return String(text[start...end])
  }
}
#endif
