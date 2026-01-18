import ArgumentParser
import Foundation
import Yams

/// Audits roadmap claims against actual codebase implementation
@main
struct RoadmapAudit: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "roadmap-audit",
    abstract: "Verify implementation status against roadmap claims",
    discussion: """
      Reads plan files with code_locations in frontmatter and verifies:
      - Files/symbols actually exist
      - Features marked "complete" have corresponding code
      - Detects outdated claims (e.g., "sequential only" when parallel exists)
      """
  )
  
  @Option(name: .shortAndLong, help: "Path to Plans directory")
  var plansDir: String = "Plans"
  
  @Option(name: .shortAndLong, help: "Path to source root")
  var sourceRoot: String = "."
  
  @Flag(name: .long, help: "Output as JSON")
  var json: Bool = false
  
  @Flag(name: .long, help: "Verbose output showing all checks")
  var verbose: Bool = false
  
  mutating func run() async throws {
    let plansURL = URL(fileURLWithPath: plansDir)
    let sourceURL = URL(fileURLWithPath: sourceRoot)
    
    // Parse all plan files
    let plans = try parsePlanFiles(at: plansURL)
    
    // Audit each plan
    var results: [AuditResult] = []
    for plan in plans {
      let result = try audit(plan: plan, sourceRoot: sourceURL)
      results.append(result)
    }
    
    // Generate report
    let report = AuditReport(
      results: results,
      totalPlans: plans.count,
      totalChecks: results.flatMap { $0.checks }.count,
      failedChecks: results.flatMap { $0.checks }.filter { !$0.passed }.count
    )
    
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(report)
      print(String(data: data, encoding: .utf8)!)
    } else {
      printHumanReport(report)
    }
  }
  
  // MARK: - Parsing
  
  func parsePlanFiles(at url: URL) throws -> [PlanFile] {
    let fm = FileManager.default
    var results: [PlanFile] = []
    
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
      return results
    }
    
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "md" else { continue }
      guard !fileURL.path.contains("/Archive/") else { continue }
      
      let content = try String(contentsOf: fileURL, encoding: .utf8)
      if let plan = parsePlan(content: content, file: fileURL.lastPathComponent) {
        results.append(plan)
      }
    }
    
    return results
  }
  
  func parsePlan(content: String, file: String) -> PlanFile? {
    guard content.hasPrefix("---") else { return nil }
    
    let parts = content.components(separatedBy: "---")
    guard parts.count >= 3 else { return nil }
    
    let yaml = parts[1]
    guard let frontmatter = try? Yams.load(yaml: yaml) as? [String: Any] else { return nil }
    
    let title = frontmatter["title"] as? String ?? file
    let status = frontmatter["status"] as? String ?? "unknown"
    
    var codeLocations: [CodeLocation] = []
    if let locations = frontmatter["code_locations"] as? [[String: Any]] {
      for loc in locations {
        if let filePath = loc["file"] as? String {
          codeLocations.append(CodeLocation(
            file: filePath,
            lines: loc["lines"] as? String,
            description: loc["description"] as? String
          ))
        }
      }
    }
    
    // Extract feature claims from content
    let claims = extractClaims(from: content)
    
    return PlanFile(
      file: file,
      title: title,
      status: status,
      codeLocations: codeLocations,
      claims: claims
    )
  }
  
  func extractClaims(from content: String) -> [FeatureClaim] {
    var claims: [FeatureClaim] = []
    
    // Look for "✅ Complete" sections and table rows
    let patterns: [(pattern: String, status: String)] = [
      (#"\| \*\*([^*]+)\*\* \| ([^|]+) \|"#, "complete"),  // Table rows with bold feature
      (#"- \[x\] (.+)"#, "complete"),  // Checked items
      (#"✅ (.+)"#, "complete"),  // Emoji complete
    ]
    
    for (pattern, status) in patterns {
      let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
      let range = NSRange(content.startIndex..., in: content)
      
      for match in regex.matches(in: content, range: range) {
        if let featureRange = Range(match.range(at: 1), in: content) {
          let feature = String(content[featureRange]).trimmingCharacters(in: .whitespaces)
          claims.append(FeatureClaim(feature: feature, claimedStatus: status))
        }
      }
    }
    
    return claims
  }
  
  // MARK: - Auditing
  
  func audit(plan: PlanFile, sourceRoot: URL) throws -> AuditResult {
    var checks: [AuditCheck] = []
    
    // Check code locations exist
    for loc in plan.codeLocations {
      let fileURL = sourceRoot.appendingPathComponent(loc.file)
      let exists = FileManager.default.fileExists(atPath: fileURL.path)
      
      checks.append(AuditCheck(
        type: .codeLocationExists,
        description: "Code location: \(loc.file)",
        passed: exists,
        detail: exists ? nil : "File not found: \(loc.file)"
      ))
      
      // If file exists and has line range, check content
      if exists, let lines = loc.lines {
        let content = try? String(contentsOf: fileURL, encoding: .utf8)
        let lineCount = content?.components(separatedBy: "\n").count ?? 0
        
        // Parse line range like "260-500"
        let parts = lines.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2 && parts[1] <= lineCount {
          checks.append(AuditCheck(
            type: .lineRangeValid,
            description: "Lines \(lines) in \(loc.file)",
            passed: true,
            detail: nil
          ))
        } else if parts.count == 2 {
          checks.append(AuditCheck(
            type: .lineRangeValid,
            description: "Lines \(lines) in \(loc.file)",
            passed: false,
            detail: "File only has \(lineCount) lines"
          ))
        }
      }
    }
    
    // Check for specific feature implementations
    for claim in plan.claims {
      let check = verifyClaim(claim, sourceRoot: sourceRoot)
      if let check = check {
        checks.append(check)
      }
    }
    
    return AuditResult(
      file: plan.file,
      title: plan.title,
      status: plan.status,
      checks: checks
    )
  }
  
  func verifyClaim(_ claim: FeatureClaim, sourceRoot: URL) -> AuditCheck? {
    // Map feature names to code patterns to search for
    let featurePatterns: [String: (files: String, pattern: String)] = [
      "Parallel Agents": ("**/*.swift", "TaskGroup|withThrowingTaskGroup"),
      "MCP Server": ("**/*.swift", "MCPServerService|JSONRPCServer"),
      "TrackedWorktree": ("**/*.swift", "TrackedWorktree.*SwiftData|@Model.*TrackedWorktree"),
      "Merge Agent": ("**/*.swift", "merge.*Agent|MergeAgent|mergeImplementer"),
    ]
    
    for (feature, search) in featurePatterns {
      if claim.feature.lowercased().contains(feature.lowercased()) {
        // Use grep to check if pattern exists
        let result = runGrep(pattern: search.pattern, path: sourceRoot.path)
        return AuditCheck(
          type: .featureImplemented,
          description: "Feature '\(claim.feature)' implementation",
          passed: result,
          detail: result ? nil : "Pattern '\(search.pattern)' not found in codebase"
        )
      }
    }
    
    return nil
  }
  
  func runGrep(pattern: String, path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["grep", "-r", "-E", pattern, path, "--include=*.swift"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    
    try? process.run()
    process.waitUntilExit()
    
    return process.terminationStatus == 0
  }
  
  // MARK: - Reporting
  
  func printHumanReport(_ report: AuditReport) {
    print("# Roadmap Audit Report\n")
    print("Plans audited: \(report.totalPlans)")
    print("Total checks: \(report.totalChecks)")
    print("Failed checks: \(report.failedChecks)\n")
    
    for result in report.results {
      let failedCount = result.checks.filter { !$0.passed }.count
      let icon = failedCount == 0 ? "✅" : "❌"
      
      if verbose || failedCount > 0 {
        print("## \(icon) \(result.title) (\(result.file))\n")
        
        for check in result.checks {
          if verbose || !check.passed {
            let checkIcon = check.passed ? "✓" : "✗"
            print("  \(checkIcon) \(check.description)")
            if let detail = check.detail {
              print("    → \(detail)")
            }
          }
        }
        print()
      }
    }
    
    if report.failedChecks == 0 {
      print("🎉 All checks passed!")
    }
  }
}

// MARK: - Models

struct PlanFile {
  let file: String
  let title: String
  let status: String
  let codeLocations: [CodeLocation]
  let claims: [FeatureClaim]
}

struct CodeLocation: Codable {
  let file: String
  let lines: String?
  let description: String?
}

struct FeatureClaim: Codable {
  let feature: String
  let claimedStatus: String
}

struct AuditCheck: Codable {
  let type: CheckType
  let description: String
  let passed: Bool
  let detail: String?
  
  enum CheckType: String, Codable {
    case codeLocationExists
    case lineRangeValid
    case featureImplemented
    case symbolExists
  }
}

struct AuditResult: Codable {
  let file: String
  let title: String
  let status: String
  let checks: [AuditCheck]
}

struct AuditReport: Codable {
  let results: [AuditResult]
  let totalPlans: Int
  let totalChecks: Int
  let failedChecks: Int
}
