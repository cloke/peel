import ArgumentParser
import Foundation
import Yams

/// Compares GitHub issues against roadmap/plan files and reports discrepancies
@main
struct GHIssueSync: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gh-issue-sync",
    abstract: "Compare GitHub issues against roadmap/plan files",
    discussion: """
      Analyzes plan files with YAML frontmatter and compares against GitHub issues.
      Reports:
      - Issues marked closed but still shown as open in docs
      - Roadmap items without corresponding issues
      - Issues not referenced in any plan file
      """
  )
  
  @Option(name: .shortAndLong, help: "GitHub repository (owner/repo)")
  var repo: String = "cloke/peel"
  
  @Option(name: .shortAndLong, help: "Path to Plans directory")
  var plansDir: String = "Plans"
  
  @Flag(name: .long, help: "Output as JSON for machine consumption")
  var json: Bool = false
  
  @Flag(name: .long, help: "Only show problems (skip OK items)")
  var problemsOnly: Bool = false
  
  mutating func run() async throws {
    let plansURL = URL(fileURLWithPath: plansDir)
    
    // 1. Get GitHub issues via gh CLI
    let ghIssues = try await fetchGitHubIssues()
    
    // 2. Parse plan files for issue references
    let planIssues = try parsePlanFiles(at: plansURL)
    
    // 3. Compare and report
    let report = generateReport(ghIssues: ghIssues, planIssues: planIssues)
    
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(report)
      print(String(data: data, encoding: .utf8)!)
    } else {
      printHumanReport(report)
    }
  }
  
  // MARK: - GitHub Fetch
  
  func fetchGitHubIssues() async throws -> [GitHubIssue] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "gh", "issue", "list",
      "--repo", repo,
      "--state", "all",
      "--json", "number,title,state,labels",
      "--limit", "1000"
    ]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    
    try process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return try JSONDecoder().decode([GitHubIssue].self, from: data)
  }
  
  // MARK: - Plan File Parsing
  
  func parsePlanFiles(at url: URL) throws -> [PlanFileIssue] {
    let fm = FileManager.default
    var results: [PlanFileIssue] = []
    
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
      return results
    }
    
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "md" else { continue }
      guard !fileURL.path.contains("/Archive/") else { continue }
      
      let content = try String(contentsOf: fileURL, encoding: .utf8)
      let issues = extractIssues(from: content, file: fileURL.lastPathComponent)
      results.append(contentsOf: issues)
    }
    
    return results
  }
  
  func extractIssues(from content: String, file: String) -> [PlanFileIssue] {
    var results: [PlanFileIssue] = []
    
    // Extract YAML frontmatter
    if content.hasPrefix("---") {
      let parts = content.components(separatedBy: "---")
      if parts.count >= 3 {
        let yaml = parts[1]
        if let frontmatter = try? Yams.load(yaml: yaml) as? [String: Any],
           let issues = frontmatter["github_issues"] as? [[String: Any]] {
          for issue in issues {
            if let number = issue["number"] as? Int,
               let status = issue["status"] as? String {
              results.append(PlanFileIssue(
                number: number,
                status: status,
                file: file,
                source: .frontmatter
              ))
            }
          }
        }
      }
    }
    
    // Extract inline issue references: [#N](url) or (#N)
    let pattern = #"\[#(\d+)\]|\(#(\d+)\)"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(content.startIndex..., in: content)
    
    for match in regex.matches(in: content, range: range) {
      let numberRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
      if let swiftRange = Range(numberRange, in: content),
         let number = Int(content[swiftRange]) {
        // Check if it's in a checkbox
        let lineStart = content[..<swiftRange.lowerBound].lastIndex(of: "\n") ?? content.startIndex
        let line = String(content[lineStart..<swiftRange.upperBound])
        let isChecked = line.contains("[x]") || line.contains("[X]")
        let isUnchecked = line.contains("[ ]")
        
        let status: String
        if isChecked { status = "closed" }
        else if isUnchecked { status = "open" }
        else { status = "referenced" }
        
        // Avoid duplicates from frontmatter
        if !results.contains(where: { $0.number == number && $0.source == .frontmatter }) {
          results.append(PlanFileIssue(
            number: number,
            status: status,
            file: file,
            source: .inline
          ))
        }
      }
    }
    
    return results
  }
  
  // MARK: - Report Generation
  
  func generateReport(ghIssues: [GitHubIssue], planIssues: [PlanFileIssue]) -> SyncReport {
    var mismatches: [IssueMismatch] = []
    var unreferenced: [GitHubIssue] = []
    var missingIssues: [PlanFileIssue] = []
    
    let ghByNumber = Dictionary(uniqueKeysWithValues: ghIssues.map { ($0.number, $0) })
    let planByNumber = Dictionary(grouping: planIssues, by: { $0.number })
    
    // Check each plan reference
    for (number, refs) in planByNumber {
      if let gh = ghByNumber[number] {
        for ref in refs {
          let ghState = gh.state.lowercased()
          let planState = ref.status.lowercased()
          
          // Mismatch: plan says open but GH is closed (or vice versa)
          if (planState == "open" && ghState == "closed") ||
             (planState == "closed" && ghState == "open") {
            mismatches.append(IssueMismatch(
              number: number,
              title: gh.title,
              githubState: ghState,
              planState: planState,
              file: ref.file
            ))
          }
        }
      } else {
        // Issue referenced in plan but doesn't exist
        for ref in refs {
          missingIssues.append(ref)
        }
      }
    }
    
    // Find unreferenced GitHub issues
    let referencedNumbers = Set(planIssues.map { $0.number })
    for gh in ghIssues where !referencedNumbers.contains(gh.number) {
      unreferenced.append(gh)
    }
    
    return SyncReport(
      mismatches: mismatches,
      unreferencedIssues: unreferenced,
      missingIssues: missingIssues,
      totalGitHubIssues: ghIssues.count,
      totalPlanReferences: planIssues.count
    )
  }
  
  func printHumanReport(_ report: SyncReport) {
    print("# GitHub Issue Sync Report\n")
    print("GitHub issues: \(report.totalGitHubIssues)")
    print("Plan references: \(report.totalPlanReferences)\n")
    
    if !report.mismatches.isEmpty {
      print("## ❌ Status Mismatches\n")
      for m in report.mismatches {
        print("- #\(m.number) \"\(m.title)\"")
        print("  GitHub: \(m.githubState), Plan (\(m.file)): \(m.planState)")
      }
      print()
    } else if !problemsOnly {
      print("## ✅ No Status Mismatches\n")
    }
    
    if !report.unreferencedIssues.isEmpty && !problemsOnly {
      print("## 📋 Unreferenced GitHub Issues\n")
      print("These issues exist on GitHub but aren't in any plan file:\n")
      for issue in report.unreferencedIssues {
        print("- #\(issue.number) \"\(issue.title)\" (\(issue.state))")
      }
      print()
    }
    
    if !report.missingIssues.isEmpty {
      print("## ⚠️ Missing GitHub Issues\n")
      print("These are referenced in plans but don't exist on GitHub:\n")
      for ref in report.missingIssues {
        print("- #\(ref.number) in \(ref.file)")
      }
      print()
    }
  }
}

// MARK: - Models

struct GitHubIssue: Codable {
  let number: Int
  let title: String
  let state: String
  let labels: [Label]
  
  struct Label: Codable {
    let name: String
  }
}

struct PlanFileIssue {
  let number: Int
  let status: String
  let file: String
  let source: Source
  
  enum Source: String, Codable {
    case frontmatter
    case inline
  }
}

struct IssueMismatch: Codable {
  let number: Int
  let title: String
  let githubState: String
  let planState: String
  let file: String
}

struct SyncReport: Codable {
  let mismatches: [IssueMismatch]
  let unreferencedIssues: [GitHubIssue]
  let missingIssues: [PlanFileIssue]
  let totalGitHubIssues: Int
  let totalPlanReferences: Int
}

extension PlanFileIssue: Codable {}
