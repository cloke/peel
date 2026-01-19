import ArgumentParser
import Foundation
import Yams

@main
struct TranslationValidator: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "translation-validator",
    abstract: "Validate translation key parity and consistency",
    discussion: """
    Scans translation files under a translations root and reports:
    - missing or extra keys per locale
    - structural mismatches (arrays vs scalars)
    - placeholder token mismatches
    - suspect translations (identical to base locale)
    """
  )

  @Option(name: .shortAndLong, help: "Project root to scan")
  var root: String = "."

  @Option(name: .long, help: "Explicit translations directory path (overrides auto-discovery)")
  var translationsPath: String?

  @Option(name: .long, help: "Base locale code (defaults to first locale found)")
  var baseLocale: String?

  @Flag(name: .long, help: "Output as JSON")
  var json: Bool = false

  @Flag(name: .long, help: "Show summary only")
  var summary: Bool = false

  @Option(name: .long, help: "Filter issues to types: missing, extra, placeholders, types, suspects")
  var only: String?

  mutating func run() async throws {
    let rootURL = URL(fileURLWithPath: root)
    let translationRoots = try discoverTranslationRoots(rootURL: rootURL, translationsPath: translationsPath)

    guard !translationRoots.isEmpty else {
      throw ValidationError("No translations root found. Use --translations-path to specify one.")
    }

    var reports: [TranslationRootReport] = []
    for root in translationRoots {
      if let report = try analyzeTranslationRoot(rootURL: root, preferredBaseLocale: baseLocale) {
        reports.append(report)
      }
    }

    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(TranslationReport(roots: reports))
      print(String(data: data, encoding: .utf8) ?? "")
    } else {
      let filter = IssueFilter(only: only)
      printHumanReport(TranslationReport(roots: reports), summaryOnly: summary, filter: filter)
    }
  }
}

// MARK: - Discovery

func discoverTranslationRoots(rootURL: URL, translationsPath: String?) throws -> [URL] {
  if let path = translationsPath {
    return [URL(fileURLWithPath: path)]
  }

  let fm = FileManager.default
  var results: [URL] = []
  guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
    return results
  }

  for case let url as URL in enumerator {
    if url.lastPathComponent == "translations" {
      results.append(url)
      enumerator.skipDescendants()
    }
  }

  return results
}

// MARK: - Analysis

func analyzeTranslationRoot(rootURL: URL, preferredBaseLocale: String?) throws -> TranslationRootReport? {
  let fm = FileManager.default
  let localeDirs = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
    .filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

  let locales = localeDirs.map { $0.lastPathComponent }.sorted()
  guard !locales.isEmpty else {
    return nil
  }

  let baseLocale = (preferredBaseLocale != nil && locales.contains(preferredBaseLocale!))
    ? preferredBaseLocale!
    : locales.first!

  var localeData: [String: LocaleTranslationData] = [:]
  for localeDir in localeDirs {
    let locale = localeDir.lastPathComponent
    let files = collectTranslationFiles(rootURL: localeDir)
    var fileMap: [String: [String: KeyInfo]] = [:]

    for file in files {
      let relativePath = file.path.replacingOccurrences(of: localeDir.path + "/", with: "")
      let content = try String(contentsOf: file, encoding: .utf8)
      let yamlObject = try Yams.load(yaml: content)
      var keyMap: [String: KeyInfo] = [:]
      if let yamlObject = yamlObject {
        flatten(node: yamlObject, path: "", into: &keyMap)
      }
      fileMap[relativePath] = keyMap
    }

    localeData[locale] = LocaleTranslationData(files: fileMap)
  }

  let allFiles = Set(localeData.values.flatMap { $0.files.keys }).sorted()
  let baseLocaleData = localeData[baseLocale]

  var fileReports: [FileReport] = []
  for file in allFiles {
    let localesMissingFile = locales.filter { locale in
      localeData[locale]?.files[file] == nil
    }

    let allKeys = Set(locales.flatMap { locale in
      (localeData[locale]?.files[file]?.keys).map { Array($0) } ?? []
    }).sorted()
    let referenceLocale = locales.first(where: { localeData[$0]?.files[file] != nil })
    let baseLocaleForFile = baseLocaleData?.files[file] != nil ? baseLocale : (referenceLocale ?? baseLocale)
    let baseDataForFile = localeData[baseLocaleForFile]?.files[file]
    let referenceKeys = Set((localeData[referenceLocale ?? ""]?.files[file]?.keys).map { Array($0) } ?? [])

    var missingKeys: [LocaleKeyList] = []
    var extraKeys: [LocaleKeyList] = []
    var placeholderMismatches: [PlaceholderMismatch] = []
    var typeMismatches: [TypeMismatch] = []
    var suspectTranslations: [SuspectTranslation] = []

    for locale in locales {
      guard let keys = localeData[locale]?.files[file] else { continue }
      let keySet = Set(keys.keys)
      let missing = referenceKeys.subtracting(keySet)
      if !missing.isEmpty {
        missingKeys.append(LocaleKeyList(locale: locale, keys: missing.sorted()))
      }
      let extra = keySet.subtracting(referenceKeys)
      if !extra.isEmpty {
        extraKeys.append(LocaleKeyList(locale: locale, keys: extra.sorted()))
      }
    }

    for key in allKeys {
      let baseInfo = baseDataForFile?[key]

      for locale in locales {
        guard let info = localeData[locale]?.files[file]?[key] else { continue }

        if let baseInfo, baseInfo.kind != info.kind {
          typeMismatches.append(TypeMismatch(key: key, locale: locale, expected: baseInfo.kind, found: info.kind))
        }

        if let baseInfo, baseInfo.kind == ValueKind.string, info.kind == ValueKind.string {
          if baseInfo.placeholders != info.placeholders {
            placeholderMismatches.append(PlaceholderMismatch(
              key: key,
              locale: locale,
              expected: baseInfo.placeholders.sorted(),
              found: info.placeholders.sorted()
            ))
          }

          if locale != baseLocale, baseInfo.sample == info.sample {
            suspectTranslations.append(SuspectTranslation(
              key: key,
              locale: locale,
              reason: "identical to base locale",
              baseSample: baseInfo.sample,
              localeSample: info.sample
            ))
          }
        }
      }
    }

    fileReports.append(FileReport(
      file: file,
      localesMissingFile: localesMissingFile,
      missingKeys: missingKeys,
      extraKeys: extraKeys,
      placeholderMismatches: placeholderMismatches,
      typeMismatches: typeMismatches,
      suspectTranslations: suspectTranslations
    ))
  }

  return TranslationRootReport(
    path: rootURL.path,
    baseLocale: baseLocale,
    locales: locales,
    files: fileReports
  )
}

func collectTranslationFiles(rootURL: URL) -> [URL] {
  let fm = FileManager.default
  guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
    return []
  }

  var results: [URL] = []
  for case let file as URL in enumerator {
    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
    let ext = file.pathExtension.lowercased()
    if ext == "yaml" || ext == "yml" {
      results.append(file)
    }
  }
  return results
}

// MARK: - Flattening

func flatten(node: Any, path: String, into map: inout [String: KeyInfo]) {
  switch node {
  case let dict as [String: Any]:
    if !path.isEmpty {
      map[path] = KeyInfo(kind: .object, placeholders: [], sample: nil)
    }
    for (key, value) in dict {
      let newPath = path.isEmpty ? key : "\(path).\(key)"
      flatten(node: value, path: newPath, into: &map)
    }
  case _ as [Any]:
    map[path] = KeyInfo(kind: .array, placeholders: [], sample: nil)
  case let string as String:
    map[path] = KeyInfo(kind: .string, placeholders: extractPlaceholders(from: string), sample: string)
  case let number as NSNumber:
    map[path] = KeyInfo(kind: .number, placeholders: [], sample: "\(number)")
  case _ as NSNull:
    map[path] = KeyInfo(kind: .null, placeholders: [], sample: nil)
  default:
    map[path] = KeyInfo(kind: .unknown, placeholders: [], sample: nil)
  }
}

func extractPlaceholders(from value: String) -> Set<String> {
  let patterns = ["%\\{([^}]+)\\}", "\\{\\{([^}]+)\\}\\}"]
  var results = Set<String>()

  for pattern in patterns {
    let regex = try? NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..., in: value)
    regex?.enumerateMatches(in: value, range: range) { match, _, _ in
      guard let match else { return }
      if let groupRange = Range(match.range(at: 1), in: value) {
        results.insert(String(value[groupRange]))
      }
    }
  }

  return results
}

// MARK: - Reporting

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

struct LocaleTranslationData {
  var files: [String: [String: KeyInfo]]
}

struct KeyInfo {
  var kind: ValueKind
  var placeholders: Set<String>
  var sample: String?
}

enum ValueKind: String, Codable {
  case string
  case number
  case array
  case object
  case null
  case unknown
}

struct IssueFilter {
  var allowed: Set<IssueKind>

  init(only: String?) {
    guard let only, !only.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      allowed = Set(IssueKind.allCases)
      return
    }
    let parts = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    let kinds = parts.compactMap { IssueKind(rawValue: $0) }
    allowed = Set(kinds)
  }

  func includes(_ kind: IssueKind) -> Bool {
    allowed.contains(kind)
  }
}

enum IssueKind: String, CaseIterable {
  case missing
  case extra
  case placeholders
  case types
  case suspects
}

struct ReportSummary {
  var files: Int = 0
  var missingKeys: Int = 0
  var extraKeys: Int = 0
  var placeholderMismatches: Int = 0
  var typeMismatches: Int = 0
  var suspectTranslations: Int = 0
}

func printHumanReport(_ report: TranslationReport, summaryOnly: Bool, filter: IssueFilter) {
  for root in report.roots {
    print("\nTranslations: \(root.path)")
    print("Base locale: \(root.baseLocale)")
    print("Locales: \(root.locales.joined(separator: ", "))")

    var summary = ReportSummary()

    for file in root.files {
      summary.files += 1
      summary.missingKeys += file.missingKeys.reduce(0) { $0 + $1.keys.count }
      summary.extraKeys += file.extraKeys.reduce(0) { $0 + $1.keys.count }
      summary.placeholderMismatches += file.placeholderMismatches.count
      summary.typeMismatches += file.typeMismatches.count
      summary.suspectTranslations += file.suspectTranslations.count

      if summaryOnly { continue }

      print("\nFile: \(file.file)")

      if !file.localesMissingFile.isEmpty {
        print("  Missing file for locales: \(file.localesMissingFile.joined(separator: ", "))")
      }

      if filter.includes(.missing) {
        for item in file.missingKeys {
          print("  Missing keys (\(item.locale)): \(item.keys.joined(separator: ", "))")
        }
      }

      if filter.includes(.extra) {
        for item in file.extraKeys {
          print("  Extra keys (\(item.locale)): \(item.keys.joined(separator: ", "))")
        }
      }

      if filter.includes(.types) {
        for mismatch in file.typeMismatches {
          print("  Type mismatch [\(mismatch.locale)] \(mismatch.key): expected \(mismatch.expected.rawValue), found \(mismatch.found.rawValue)")
        }
      }

      if filter.includes(.placeholders) {
        for mismatch in file.placeholderMismatches {
          print("  Placeholder mismatch [\(mismatch.locale)] \(mismatch.key): expected \(mismatch.expected), found \(mismatch.found)")
        }
      }

      if filter.includes(.suspects) {
        for suspect in file.suspectTranslations {
          print("  Suspect [\(suspect.locale)] \(suspect.key): \(suspect.reason)")
        }
      }
    }

    if summaryOnly {
      print("\nSummary:")
      print("  Files: \(summary.files)")
      if filter.includes(.missing) { print("  Missing keys: \(summary.missingKeys)") }
      if filter.includes(.extra) { print("  Extra keys: \(summary.extraKeys)") }
      if filter.includes(.types) { print("  Type mismatches: \(summary.typeMismatches)") }
      if filter.includes(.placeholders) { print("  Placeholder mismatches: \(summary.placeholderMismatches)") }
      if filter.includes(.suspects) { print("  Suspect translations: \(summary.suspectTranslations)") }
    }
  }
}
