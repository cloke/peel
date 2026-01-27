import Foundation

struct CLIOptions {
  var port: Int = 8765
  var command: String?
  var prompt: String?
  var templateId: String?
  var templateName: String?
  var workingDirectory: String?
  var enableReviewLoop: Bool?
  var allowPlannerModelSelection: Bool?
  var allowPlannerImplementerScaling: Bool?
  var maxImplementers: Int?
  var maxPremiumCost: Double?
  var priority: Int?
  var timeoutSeconds: Double?
  var requireRagUsage: Bool?
  var runsJSONPath: String?
  var batchParallel: Bool?
  var returnImmediately: Bool?
  var keepWorkspace: Bool?
  var runId: String?
  var limit: Int?
  var includeResults: Bool?
  var includeOutputs: Bool?
  var chainId: String?
  var repoPath: String?
  var chainSpecJSONPath: String?
  var toolName: String?
  var argumentsJSONPath: String?
  var diffOnly: Bool = false
  var outputPath: String?
  // Polling options
  var pollInterval: Double = 5.0
  var pollMaxDuration: Double = 3600.0
  var pollBackoff: Double = 1.5
  var pollMaxInterval: Double = 30.0
  var pollLogPath: String?
}

enum CLIError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    }
  }
}

@main
struct PeelCLI {
  static func main() async {
    do {
      let options = try parseArguments()
      try await run(options: options)
    } catch {
      writeError(error.localizedDescription)
      exit(EXIT_FAILURE)
    }
  }
}

private func parseArguments() throws -> CLIOptions {
  var options = CLIOptions()
  var iterator = ProcessInfo.processInfo.arguments.dropFirst().makeIterator()

  while let arg = iterator.next() {
    switch arg {
    case "--port":
      guard let value = iterator.next(), let port = Int(value) else {
        throw CLIError.message("--port requires an integer value")
      }
      options.port = port
    case "--prompt":
      options.prompt = iterator.next()
    case "--template-id":
      options.templateId = iterator.next()
    case "--template-name":
      options.templateName = iterator.next()
    case "--working-directory":
      options.workingDirectory = iterator.next()
    case "--enable-review-loop":
      options.enableReviewLoop = true
    case "--disable-review-loop":
      options.enableReviewLoop = false
    case "--allow-planner-model-selection":
      options.allowPlannerModelSelection = true
    case "--allow-planner-implementer-scaling":
      options.allowPlannerImplementerScaling = true
    case "--max-implementers":
      guard let value = iterator.next(), let maxImplementers = Int(value) else {
        throw CLIError.message("--max-implementers requires an integer value")
      }
      options.maxImplementers = maxImplementers
    case "--max-premium-cost":
      guard let value = iterator.next(), let maxPremiumCost = Double(value) else {
        throw CLIError.message("--max-premium-cost requires a number value")
      }
      options.maxPremiumCost = maxPremiumCost
    case "--priority":
      guard let value = iterator.next(), let priority = Int(value) else {
        throw CLIError.message("--priority requires an integer value")
      }
      options.priority = priority
    case "--timeout-seconds":
      guard let value = iterator.next(), let timeoutSeconds = Double(value) else {
        throw CLIError.message("--timeout-seconds requires a number value")
      }
      options.timeoutSeconds = timeoutSeconds
    case "--require-rag-usage":
      options.requireRagUsage = true
    case "--runs-json":
      options.runsJSONPath = iterator.next()
    case "--parallel":
      options.batchParallel = true
    case "--sequential":
      options.batchParallel = false
    case "--return-immediately":
      options.returnImmediately = true
    case "--keep-workspace":
      options.keepWorkspace = true
    case "--run-id":
      options.runId = iterator.next()
    case "--limit":
      guard let value = iterator.next(), let limit = Int(value) else {
        throw CLIError.message("--limit requires an integer value")
      }
      options.limit = limit
    case "--include-results":
      options.includeResults = true
    case "--include-outputs":
      options.includeOutputs = true
    case "--chain-id":
      options.chainId = iterator.next()
    case "--repo-path":
      options.repoPath = iterator.next()
    case "--chain-spec-json":
      options.chainSpecJSONPath = iterator.next()
    case "--tool-name":
      options.toolName = iterator.next()
    case "--arguments-json":
      options.argumentsJSONPath = iterator.next()
    case "--poll-interval":
      guard let value = iterator.next(), let interval = Double(value) else {
        throw CLIError.message("--poll-interval requires a number value")
      }
      options.pollInterval = interval
    case "--poll-max-duration":
      guard let value = iterator.next(), let duration = Double(value) else {
        throw CLIError.message("--poll-max-duration requires a number value")
      }
      options.pollMaxDuration = duration
    case "--poll-backoff":
      guard let value = iterator.next(), let backoff = Double(value) else {
        throw CLIError.message("--poll-backoff requires a number value")
      }
      options.pollBackoff = backoff
    case "--poll-max-interval":
      guard let value = iterator.next(), let maxInterval = Double(value) else {
        throw CLIError.message("--poll-max-interval requires a number value")
      }
      options.pollMaxInterval = maxInterval
    case "--poll-log":
      options.pollLogPath = iterator.next()
    case "--diff-only":
      options.diffOnly = true
    case "--output", "-o":
      options.outputPath = iterator.next()
    case "-h", "--help":
      print(usageText())
      exit(EXIT_SUCCESS)
    default:
      if options.command == nil {
        options.command = arg
      } else {
        throw CLIError.message("Unexpected argument: \(arg)")
      }
    }
  }

  return options
}

private func run(options: CLIOptions) async throws {
  guard let command = options.command else {
    throw CLIError.message(usageText())
  }

  switch command {
  case "tools-list":
    try await printRPCResult(method: "tools/list", params: nil, port: options.port)
  case "tools-call":
    guard let toolName = options.toolName, !toolName.isEmpty else {
      throw CLIError.message("tools-call requires --tool-name <name>")
    }
    let arguments = try loadArgumentsJSON(options.argumentsJSONPath)
    try await printRPCResult(method: "tools/call", params: [
      "name": toolName,
      "arguments": arguments
    ], port: options.port)
  case "templates-list":
    try await printRPCResult(method: "tools/call", params: [
      "name": "templates.list",
      "arguments": [:]
    ], port: options.port)
  case "chains-run":
    guard let prompt = options.prompt, !prompt.isEmpty else {
      throw CLIError.message("chains-run requires --prompt")
    }

    var arguments: [String: Any] = ["prompt": prompt]
    if let templateId = options.templateId { arguments["templateId"] = templateId }
    if let templateName = options.templateName { arguments["templateName"] = templateName }
    if let workingDirectory = options.workingDirectory { arguments["workingDirectory"] = workingDirectory }
    if let enableReviewLoop = options.enableReviewLoop { arguments["enableReviewLoop"] = enableReviewLoop }
    if let allowPlannerModelSelection = options.allowPlannerModelSelection {
      arguments["allowPlannerModelSelection"] = allowPlannerModelSelection
    }
    if let allowPlannerImplementerScaling = options.allowPlannerImplementerScaling {
      arguments["allowPlannerImplementerScaling"] = allowPlannerImplementerScaling
    }
    if let maxImplementers = options.maxImplementers { arguments["maxImplementers"] = maxImplementers }
    if let maxPremiumCost = options.maxPremiumCost { arguments["maxPremiumCost"] = maxPremiumCost }
    if let priority = options.priority { arguments["priority"] = priority }
    if let timeoutSeconds = options.timeoutSeconds { arguments["timeoutSeconds"] = timeoutSeconds }
    if let requireRagUsage = options.requireRagUsage { arguments["requireRagUsage"] = requireRagUsage }
    if let returnImmediately = options.returnImmediately {
      arguments["returnImmediately"] = returnImmediately
    }
    if let keepWorkspace = options.keepWorkspace {
      arguments["keepWorkspace"] = keepWorkspace
    }
    if let chainSpecPath = options.chainSpecJSONPath {
      let url = URL(fileURLWithPath: chainSpecPath)
      let data = try Data(contentsOf: url)
      let json = try JSONSerialization.jsonObject(with: data, options: [])
      guard let spec = json as? [String: Any] else {
        throw CLIError.message("--chain-spec-json must be a JSON object")
      }
      arguments["chainSpec"] = spec
    }

    try await printRPCResult(method: "tools/call", params: [
      "name": "chains.run",
      "arguments": arguments
    ], port: options.port)
  case "chains-run-batch":
    guard let runsPath = options.runsJSONPath, !runsPath.isEmpty else {
      throw CLIError.message("chains-run-batch requires --runs-json <path>")
    }
    let url = URL(fileURLWithPath: runsPath)
    let data = try Data(contentsOf: url)
    let json = try JSONSerialization.jsonObject(with: data, options: [])
    let runs: [[String: Any]]
    if let root = json as? [String: Any], let list = root["runs"] as? [[String: Any]] {
      runs = list
    } else if let list = json as? [[String: Any]] {
      runs = list
    } else {
      throw CLIError.message("--runs-json must be an array or object with 'runs'")
    }

    var arguments: [String: Any] = ["runs": runs]
    if let parallel = options.batchParallel {
      arguments["parallel"] = parallel
    }

    try await printRPCResult(method: "tools/call", params: [
      "name": "chains.runBatch",
      "arguments": arguments
    ], port: options.port)
  case "chains-run-status":
    guard let runId = options.runId, !runId.isEmpty else {
      throw CLIError.message("chains-run-status requires --run-id <uuid>")
    }
    try await printRPCResult(method: "tools/call", params: [
      "name": "chains.run.status",
      "arguments": ["runId": runId]
    ], port: options.port)
  case "chains-run-list":
    var arguments: [String: Any] = [:]
    if let limit = options.limit { arguments["limit"] = limit }
    if let chainId = options.chainId { arguments["chainId"] = chainId }
    if let runId = options.runId { arguments["runId"] = runId }
    if let includeResults = options.includeResults { arguments["includeResults"] = includeResults }
    if let includeOutputs = options.includeOutputs { arguments["includeOutputs"] = includeOutputs }
    try await printRPCResult(method: "tools/call", params: [
      "name": "chains.run.list",
      "arguments": arguments
    ], port: options.port)
  case "parallel-create":
    let arguments = try loadArgumentsJSON(options.argumentsJSONPath)
    try await printRPCResult(method: "tools/call", params: [
      "name": "parallel.create",
      "arguments": arguments
    ], port: options.port)
  case "parallel-start":
    guard let runId = options.runId, !runId.isEmpty else {
      throw CLIError.message("parallel-start requires --run-id <uuid>")
    }
    try await printRPCResult(method: "tools/call", params: [
      "name": "parallel.start",
      "arguments": ["runId": runId]
    ], port: options.port)
  case "parallel-status":
    guard let runId = options.runId, !runId.isEmpty else {
      throw CLIError.message("parallel-status requires --run-id <uuid>")
    }
    try await printRPCResult(method: "tools/call", params: [
      "name": "parallel.status",
      "arguments": ["runId": runId]
    ], port: options.port)
  case "workspaces-agent-list":
    var arguments: [String: Any] = [:]
    if let repoPath = options.repoPath { arguments["repoPath"] = repoPath }
    try await printRPCResult(method: "tools/call", params: [
      "name": "workspaces.agent.list",
      "arguments": arguments
    ], port: options.port)
  case "workspaces-agent-cleanup-status":
    try await printRPCResult(method: "tools/call", params: [
      "name": "workspaces.agent.cleanup.status",
      "arguments": [:]
    ], port: options.port)
  case "chains-poll":
    guard let runId = options.runId, !runId.isEmpty else {
      throw CLIError.message("chains-poll requires --run-id <uuid>")
    }
    try await runChainsPoll(options: options, runId: runId)
  case "rag-pattern-check":
    try await runRagPatternCheck(options: options)
  case "rag-audit":
    try await runRagAudit(options: options)
  case "server-stop":
    try await printRPCResult(method: "tools/call", params: [
      "name": "server.stop",
      "arguments": [:]
    ], port: options.port)
  case "app-quit":
    try await printRPCResult(method: "tools/call", params: [
      "name": "app.quit",
      "arguments": [:]
    ], port: options.port)
  default:
    throw CLIError.message("Unknown command: \(command)\n\n\(usageText())")
  }
}

private func printRPCResult(method: String, params: [String: Any]?, port: Int) async throws {
  let client = MCPClient(port: port)
  let response = try await client.call(method: method, params: params)

  let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted])
  if let text = String(data: data, encoding: .utf8) {
    print(text)
  } else {
    print(response)
  }
}

private func usageText() -> String {
  """
  Peel MCP CLI

  Usage:
    peel-mcp [--port <port>] <command> [options]

  Commands:
    tools-list
    tools-call --tool-name <name> [--arguments-json <path>]
    templates-list
    chains-run --prompt <text> [--template-id <uuid> | --template-name <name>] [--working-directory <path>] [--enable-review-loop|--disable-review-loop]
      [--allow-planner-model-selection] [--allow-planner-implementer-scaling]
      [--max-implementers <int>] [--max-premium-cost <number>] [--priority <int>] [--timeout-seconds <number>] [--require-rag-usage] [--return-immediately]
      [--chain-spec-json <path>]
    chains-run-batch --runs-json <path> [--parallel|--sequential]
    chains-run-status --run-id <uuid>
    chains-run-list [--limit <int>] [--chain-id <id>] [--run-id <uuid>] [--include-results] [--include-outputs]
    chains-poll --run-id <uuid> [--poll-interval <sec>] [--poll-max-duration <sec>] [--poll-backoff <factor>] [--poll-max-interval <sec>] [--poll-log <path>]
    parallel-create --arguments-json <path>
    parallel-start --run-id <uuid>
    parallel-status --run-id <uuid>
    workspaces-agent-list [--repo-path <path>]
    workspaces-agent-cleanup-status
    rag-pattern-check [--repo-path <path>] [--limit <int>] [--diff-only]
    rag-audit --repo-path <path> [--output <path>] [--limit <int>]
    server-stop
    app-quit

  Polling Options (for chains-poll):
    --poll-interval <sec>      Initial poll interval in seconds (default: 5)
    --poll-max-duration <sec>  Maximum total polling time in seconds (default: 3600)
    --poll-backoff <factor>    Backoff multiplier after each poll (default: 1.5)
    --poll-max-interval <sec>  Maximum poll interval after backoff (default: 30)
    --poll-log <path>          Path to write status snapshots for debugging
  """
}

// MARK: - Chains Polling

/// Poll a chain run status with exponential backoff until completion or timeout
private func runChainsPoll(options: CLIOptions, runId: String) async throws {
  let client = MCPClient(port: options.port)
  let startTime = Date()
  var currentInterval = options.pollInterval
  var pollCount = 0
  var lastStatus: String?
  var inReviewGate = false

  // Open log file if specified
  var logFileHandle: FileHandle?
  if let logPath = options.pollLogPath {
    FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
    logFileHandle = FileHandle(forWritingAtPath: logPath)
  }
  defer { logFileHandle?.closeFile() }

  func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let handle = logFileHandle, let data = line.data(using: .utf8) {
      handle.write(data)
    }
  }

  log("Starting poll for runId: \(runId)")
  log("Settings: interval=\(options.pollInterval)s, maxDuration=\(options.pollMaxDuration)s, backoff=\(options.pollBackoff)x, maxInterval=\(options.pollMaxInterval)s")

  while true {
    pollCount += 1
    let elapsed = Date().timeIntervalSince(startTime)

    // Check timeout
    if elapsed >= options.pollMaxDuration {
      log("Max duration exceeded (\(Int(elapsed))s >= \(Int(options.pollMaxDuration))s)")
      writeError("Polling timed out after \(Int(elapsed)) seconds (\(pollCount) polls)")
      throw CLIError.message("Polling timed out after \(Int(elapsed)) seconds")
    }

    // Fetch status
    let response: [String: Any]
    do {
      response = try await client.call(method: "tools/call", params: [
        "name": "chains.run.status",
        "arguments": ["runId": runId]
      ])
    } catch {
      log("Poll \(pollCount) failed: \(error.localizedDescription)")
      writeError("Poll \(pollCount) failed: \(error.localizedDescription)")
      // Apply backoff and continue
      currentInterval = min(currentInterval * options.pollBackoff, options.pollMaxInterval)
      try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
      continue
    }

    // Extract status from response
    let status = extractChainStatus(from: response)
    let isComplete = status == "completed" || status == "failed" || status == "cancelled" || status == "stopped"
    let isReviewGate = extractReviewGate(from: response)

    // Log status change
    if status != lastStatus {
      log("Poll \(pollCount): status changed to '\(status ?? "unknown")'")
      lastStatus = status
    }

    // Detect review gate entry
    if isReviewGate && !inReviewGate {
      inReviewGate = true
      log("Poll \(pollCount): REVIEW GATE DETECTED")
      print("⚠️  Review gate reached - chain awaiting approval")
    }

    // Log snapshot to file
    if let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted]),
       let text = String(data: data, encoding: .utf8) {
      log("Status snapshot:\n\(text)")
    }

    // Check completion
    if isComplete {
      log("Poll \(pollCount): Chain completed with status '\(status ?? "unknown")'")
      print("✅ Chain completed: \(status ?? "unknown")")
      // Print final result
      let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted])
      if let text = String(data: data, encoding: .utf8) {
        print(text)
      }
      return
    }

    // Progress indicator
    let statusStr = status ?? "unknown"
    let intervalStr = String(format: "%.1f", currentInterval)
    print("⏳ [\(pollCount)] Status: \(statusStr) | Elapsed: \(Int(elapsed))s | Next poll in \(intervalStr)s")

    // Sleep with backoff
    try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
    currentInterval = min(currentInterval * options.pollBackoff, options.pollMaxInterval)
  }
}

/// Extract the chain status string from a chains.run.status response
private func extractChainStatus(from response: [String: Any]) -> String? {
  // Response structure: { result: { result: { status: "..." } } } or { result: { status: "..." } }
  if let result = response["result"] as? [String: Any] {
    if let inner = result["result"] as? [String: Any], let status = inner["status"] as? String {
      return status
    }
    if let status = result["status"] as? String {
      return status
    }
  }
  return nil
}

/// Check if the chain is in a review gate state
private func extractReviewGate(from response: [String: Any]) -> Bool {
  if let result = response["result"] as? [String: Any] {
    if let inner = result["result"] as? [String: Any] {
      if let awaitingReview = inner["awaitingReview"] as? Bool, awaitingReview {
        return true
      }
      if let status = inner["status"] as? String, status == "review_gate" {
        return true
      }
    }
    if let awaitingReview = result["awaitingReview"] as? Bool, awaitingReview {
      return true
    }
    if let status = result["status"] as? String, status == "review_gate" {
      return true
    }
  }
  return false
}

// MARK: - RAG Pattern Check

private func runRagPatternCheck(options: CLIOptions) async throws {
  let repoPath = options.repoPath
  let limit = options.limit ?? 5
  let diffOnly = options.diffOnly

  let patterns: [(label: String, query: String)] = [
    ("ObservableObject", "ObservableObject"),
    ("@Published", "@Published"),
    ("@StateObject", "@StateObject"),
    ("@ObservedObject", "@ObservedObject"),
    ("NavigationView", "NavigationView"),
    ("Combine import", "import Combine"),
    ("DispatchQueue.main", "DispatchQueue.main"),
    ("try!", "try!"),
    ("DateFormatter alloc", "DateFormatter()")
  ]

  if diffOnly {
    // Scan only staged changes using git diff --cached
    try runDiffOnlyPatternCheck(patterns: patterns, repoPath: repoPath)
  } else {
    // Full RAG search via MCP
    let client = MCPClient(port: options.port)
    var totalMatches = 0
    for pattern in patterns {
      var arguments: [String: Any] = [
        "query": pattern.query,
        "mode": "text",
        "limit": limit
      ]
      if let repoPath { arguments["repoPath"] = repoPath }

      let response = try await client.call(method: "tools/call", params: [
        "name": "rag.search",
        "arguments": arguments
      ])

      let matchCount = extractResultCount(from: response)
      if matchCount > 0 {
        totalMatches += matchCount
        print("- \(pattern.label): \(matchCount) match(es)")
      }
    }

    if totalMatches == 0 {
      print("No pattern matches found.")
    }
  }
}

private func runDiffOnlyPatternCheck(patterns: [(label: String, query: String)], repoPath: String?) throws {
  // Get staged diff content
  let workDir = repoPath ?? FileManager.default.currentDirectoryPath
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["diff", "--cached", "--no-color"]
  process.currentDirectoryURL = URL(fileURLWithPath: workDir)

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice

  try process.run()
  process.waitUntilExit()

  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let diffOutput = String(data: data, encoding: .utf8) ?? ""

  if diffOutput.isEmpty {
    print("No staged changes found.")
    return
  }

  // Parse diff and extract only added lines (lines starting with +, but not +++)
  let addedLines = diffOutput
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
    .map { String($0.dropFirst()) }  // Remove the leading +
    .joined(separator: "\n")

  if addedLines.isEmpty {
    print("No added lines in staged changes.")
    return
  }

  var totalMatches = 0
  for pattern in patterns {
    var matchCount = 0
    for line in addedLines.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.contains(pattern.query) {
        matchCount += 1
      }
    }
    if matchCount > 0 {
      totalMatches += matchCount
      print("- \(pattern.label): \(matchCount) match(es) in staged changes")
    }
  }

  if totalMatches == 0 {
    print("No pattern matches in staged changes. ✅")
  } else {
    print("\nTotal: \(totalMatches) deprecated pattern(s) found in staged changes.")
  }
}

// MARK: - RAG Audit

struct AuditResult {
  let pattern: String
  let filePath: String
  let startLine: Int
  let endLine: Int
  let snippet: String
}

private func runRagAudit(options: CLIOptions) async throws {
  guard let repoPath = options.repoPath else {
    throw CLIError.message("rag-audit requires --repo-path")
  }

  let client = MCPClient(port: options.port)
  let limit = options.limit ?? 20

  let patterns: [(label: String, query: String, severity: String)] = [
    ("ObservableObject", "ObservableObject", "warning"),
    ("@Published", "@Published", "warning"),
    ("@StateObject", "@StateObject", "warning"),
    ("@ObservedObject", "@ObservedObject", "warning"),
    ("NavigationView", "NavigationView", "warning"),
    ("Combine import", "import Combine", "info"),
    ("DispatchQueue.main", "DispatchQueue.main", "warning"),
    ("try!", "try!", "error"),
    ("DateFormatter alloc", "DateFormatter()", "info")
  ]

  var allResults: [(pattern: String, severity: String, results: [[String: Any]])] = []
  var totalMatches = 0

  print("🔍 Running RAG audit on \(repoPath)...\n")

  for pattern in patterns {
    let arguments: [String: Any] = [
      "query": pattern.query,
      "repoPath": repoPath,
      "mode": "text",
      "limit": limit
    ]

    let response = try await client.call(method: "tools/call", params: [
      "name": "rag.search",
      "arguments": arguments
    ])

    let results = extractResultsArray(from: response)
    if !results.isEmpty {
      allResults.append((pattern.label, pattern.severity, results))
      totalMatches += results.count
      print("  \(pattern.label): \(results.count) match(es)")
    }
  }

  // Generate markdown report
  let report = generateAuditReport(repoPath: repoPath, results: allResults, totalMatches: totalMatches)

  if let outputPath = options.outputPath {
    try report.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("\n📄 Report written to: \(outputPath)")
  } else {
    print("\n" + report)
  }
}

private func extractResultsArray(from response: [String: Any]) -> [[String: Any]] {
  if let result = response["result"] as? [String: Any] {
    if let inner = result["result"] as? [String: Any],
       let results = inner["results"] as? [[String: Any]] {
      return results
    }
    if let results = result["results"] as? [[String: Any]] {
      return results
    }
  }
  return []
}

private func generateAuditReport(
  repoPath: String,
  results: [(pattern: String, severity: String, results: [[String: Any]])],
  totalMatches: Int
) -> String {
  let dateFormatter = ISO8601DateFormatter()
  let timestamp = dateFormatter.string(from: Date())

  var lines: [String] = []
  lines.append("# RAG Audit Report")
  lines.append("")
  lines.append("**Repository:** `\(repoPath)`")
  lines.append("**Generated:** \(timestamp)")
  lines.append("**Total Matches:** \(totalMatches)")
  lines.append("")

  if results.isEmpty {
    lines.append("✅ No deprecated patterns found!")
    return lines.joined(separator: "\n")
  }

  // Summary table
  lines.append("## Summary")
  lines.append("")
  lines.append("| Pattern | Severity | Count |")
  lines.append("|---------|----------|-------|")
  for (pattern, severity, matches) in results {
    let icon = severity == "error" ? "🔴" : (severity == "warning" ? "🟡" : "🔵")
    lines.append("| \(pattern) | \(icon) \(severity) | \(matches.count) |")
  }
  lines.append("")

  // Detailed findings
  lines.append("## Detailed Findings")
  lines.append("")

  for (pattern, severity, matches) in results {
    let icon = severity == "error" ? "🔴" : (severity == "warning" ? "🟡" : "🔵")
    lines.append("### \(icon) \(pattern)")
    lines.append("")

    for match in matches {
      let filePath = match["filePath"] as? String ?? "unknown"
      let startLine = match["startLine"] as? Int ?? 0
      let endLine = match["endLine"] as? Int ?? 0
      let snippet = match["snippet"] as? String ?? ""

      // Make relative path
      let relativePath = filePath.hasPrefix(repoPath)
        ? String(filePath.dropFirst(repoPath.count + 1))
        : filePath

      lines.append("- [\(relativePath)#L\(startLine)-L\(endLine)](\(relativePath)#L\(startLine)-L\(endLine))")

      // Show first line of snippet
      if let firstLine = snippet.split(separator: "\n", omittingEmptySubsequences: true).first {
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          lines.append("  ```")
          lines.append("  \(String(trimmed.prefix(80)))")
          lines.append("  ```")
        }
      }
    }
    lines.append("")
  }

  // Recommendations
  lines.append("## Recommendations")
  lines.append("")
  lines.append("| Pattern | Modern Alternative |")
  lines.append("|---------|-------------------|")
  lines.append("| `ObservableObject` | Use `@Observable` macro |")
  lines.append("| `@Published` | Properties in `@Observable` class |")
  lines.append("| `@StateObject` | Use `@State` with `@Observable` |")
  lines.append("| `@ObservedObject` | Use `@Bindable` or `@Environment` |")
  lines.append("| `NavigationView` | Use `NavigationStack` |")
  lines.append("| `DispatchQueue.main` | Use `@MainActor` |")
  lines.append("| `try!` | Use `do/catch` or `try?` |")
  lines.append("")
  lines.append("See `Docs/reference/CODE_AUDIT_INDEX.md` for migration guides.")

  return lines.joined(separator: "\n")
}

private func extractResultCount(from response: [String: Any]) -> Int {
  if let result = response["result"] as? [String: Any] {
    if let inner = result["result"] as? [String: Any],
       let results = inner["results"] as? [Any] {
      return results.count
    }
    if let results = result["results"] as? [Any] {
      return results.count
    }
  }
  return 0
}

private func loadArgumentsJSON(_ path: String?) throws -> [String: Any] {
  guard let path else {
    return [:]
  }

  let url = URL(fileURLWithPath: path)
  let data = try Data(contentsOf: url)
  let json = try JSONSerialization.jsonObject(with: data, options: [])
  guard let dict = json as? [String: Any] else {
    throw CLIError.message("--arguments-json must be a JSON object")
  }
  return dict
}

private func writeError(_ message: String) {
  if let data = (message + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

struct MCPClient {
  let port: Int
  private let session: URLSession

  init(port: Int) {
    self.port = port
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 600
    config.timeoutIntervalForResource = 600
    self.session = URLSession(configuration: config)
  }

  func call(method: String, params: [String: Any]?) async throws -> [String: Any] {
    var body: [String: Any] = [
      "jsonrpc": "2.0",
      "id": Int(Date().timeIntervalSince1970),
      "method": method
    ]

    if let params {
      body["params"] = params
    }

    let requestData = try JSONSerialization.data(withJSONObject: body, options: [])
    guard let url = URL(string: "http://127.0.0.1:\(port)/rpc") else {
      throw CLIError.message("Invalid MCP URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = requestData
    request.timeoutInterval = 600

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CLIError.message("No HTTP response")
    }

    guard (200...299).contains(http.statusCode) else {
      let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
      throw CLIError.message(errorText)
    }

    let json = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = json as? [String: Any] else {
      throw CLIError.message("Invalid response JSON")
    }

    return dict
  }
}
