import ArgumentParser
import Foundation

@main
struct PatternAudit: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pattern-audit",
    abstract: "Scan for deprecated Swift/SwiftUI patterns",
    discussion: """
      Scans Swift files for known deprecated patterns and produces a summary report.
      """
  )

  @Option(name: .shortAndLong, help: "Path to source root")
  var sourceRoot: String = "."

  @Option(name: .shortAndLong, help: "Output format: human or json")
  var output: OutputFormat = .human

  @Flag(name: .long, help: "Verbose output with file locations")
  var verbose: Bool = false

  mutating func run() async throws {
    let rootURL = URL(fileURLWithPath: sourceRoot)
    let patterns = DeprecatedPattern.defaults
    let scanner = PatternScanner()

    var results: [PatternResult] = []
    for pattern in patterns {
      let matches = scanner.run(pattern: pattern, path: rootURL.path)
      results.append(PatternResult(pattern: pattern, matches: matches))
    }

    let report = AuditReport(
      generatedAt: Date(),
      sourceRoot: rootURL.path,
      results: results
    )

    switch output {
    case .human:
      printHumanReport(report, verbose: verbose)
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(report)
      print(String(decoding: data, as: UTF8.self))
    }
  }
}

// MARK: - Models

enum OutputFormat: String, ExpressibleByArgument, Codable {
  case human
  case json
}

enum PatternCategory: String, Codable, CaseIterable {
  case swiftui
  case concurrency
  case errorHandling
  case formatting
  case preview

  var displayName: String {
    switch self {
    case .swiftui: return "SwiftUI"
    case .concurrency: return "Concurrency"
    case .errorHandling: return "Error Handling"
    case .formatting: return "Formatting"
    case .preview: return "Preview"
    }
  }
}

struct DeprecatedPattern: Codable, Identifiable {
  let id: String
  let label: String
  let grepPattern: String
  let replacement: String
  let category: PatternCategory

  static let defaults: [DeprecatedPattern] = [
    .init(id: "observableObject", label: "ObservableObject", grepPattern: "ObservableObject", replacement: "@Observable", category: .swiftui),
    .init(id: "published", label: "@Published", grepPattern: "@Published", replacement: "Direct properties", category: .swiftui),
    .init(id: "stateObject", label: "@StateObject", grepPattern: "@StateObject", replacement: "@State", category: .swiftui),
    .init(id: "observedObject", label: "@ObservedObject", grepPattern: "@ObservedObject", replacement: "@Environment / passed reference", category: .swiftui),
    .init(id: "navigationView", label: "NavigationView", grepPattern: "NavigationView", replacement: "NavigationStack", category: .swiftui),
    .init(id: "combineImport", label: "import Combine", grepPattern: "import Combine", replacement: "async/await", category: .concurrency),
    .init(id: "dispatchMain", label: "DispatchQueue.main", grepPattern: "DispatchQueue\\.main", replacement: "@MainActor", category: .concurrency),
    .init(id: "tryBang", label: "try!", grepPattern: "try!", replacement: "do/catch", category: .errorHandling),
    .init(id: "previewProvider", label: "PreviewProvider", grepPattern: "PreviewProvider", replacement: "#Preview", category: .preview),
    .init(id: "dateFormatter", label: "DateFormatter()", grepPattern: "DateFormatter\\(", replacement: "Cached formatter", category: .formatting)
  ]
}

struct PatternMatch: Codable, Identifiable {
  let id: String
  let file: String
  let line: Int
  let text: String
}

struct PatternResult: Codable {
  let pattern: DeprecatedPattern
  let matches: [PatternMatch]
}

struct AuditReport: Codable {
  let generatedAt: Date
  let sourceRoot: String
  let results: [PatternResult]

  var totalMatches: Int {
    results.reduce(0) { $0 + $1.matches.count }
  }
}

// MARK: - Scanner

struct PatternScanner {
  func run(pattern: DeprecatedPattern, path: String) -> [PatternMatch] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "grep",
      "-r",
      "-n",
      "-E",
      pattern.grepPattern,
      path,
      "--include=*.swift"
    ]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return []
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)

    return output
      .split(separator: "\n")
      .compactMap { line in
        parseMatch(String(line), patternId: pattern.id)
      }
  }

  private func parseMatch(_ line: String, patternId: String) -> PatternMatch? {
    let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return nil }
    let file = String(parts[0])
    let lineNumber = Int(parts[1]) ?? 0
    let text = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
    return PatternMatch(
      id: "\(patternId):\(file):\(lineNumber)",
      file: file,
      line: lineNumber,
      text: text
    )
  }
}

// MARK: - Reporting

func printHumanReport(_ report: AuditReport, verbose: Bool) {
  print("# Pattern Audit Report\n")
  print("Source root: \(report.sourceRoot)")
  print("Generated: \(report.generatedAt)\n")
  print("Total matches: \(report.totalMatches)\n")

  let grouped = Dictionary(grouping: report.results) { $0.pattern.category }
  for category in PatternCategory.allCases {
    guard let results = grouped[category] else { continue }
    let categoryTotal = results.reduce(0) { $0 + $1.matches.count }
    if categoryTotal == 0 { continue }

    print("## \(category.displayName) (\(categoryTotal))\n")
    for result in results where !result.matches.isEmpty {
      print("- \(result.pattern.label): \(result.matches.count)")
      if verbose {
        for match in result.matches {
          print("  - \(match.file):\(match.line): \(match.text)")
        }
      }
    }
    print("")
  }

  if report.totalMatches == 0 {
    print("🎉 No deprecated patterns found.")
  }
}
