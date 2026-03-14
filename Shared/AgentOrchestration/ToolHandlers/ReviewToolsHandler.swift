//
//  ReviewToolsHandler.swift
//  Peel
//
//  Automated code review tools. Dispatches agent-based reviews of
//  worktree executions with structured output and confidence scores.
//

import Foundation
import MCPCore

/// MCP tools for automated agent-driven code review.
///
/// Tools:
/// - `review.auto` — Trigger automated review of a worktree execution
/// - `review.confidence` — Get confidence assessment for an execution's review
@MainActor
final class ReviewToolsHandler: MCPToolHandler {
  let supportedTools: Set<String> = [
    "review.auto",
    "review.confidence",
  ]

  weak var delegate: MCPToolHandlerDelegate?

  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    switch name {
    case "review.auto":
      return await handleAutoReview(id: id, arguments: arguments)
    case "review.confidence":
      return handleConfidence(id: id, arguments: arguments)
    default:
      return (404, makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.methodNotFound,
        message: "Unknown review tool: \(name)"
      ))
    }
  }

  // MARK: - review.auto

  /// Build a structured review prompt for an execution's diff.
  /// The caller (an agent) uses this to perform the review and produce structured JSON output.
  private func handleAutoReview(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let repoPath = arguments["repoPath"] as? String, !repoPath.isEmpty else {
      return missingParamError(id: id, param: "repoPath")
    }

    let diff = arguments["diff"] as? String ?? ""
    let branch = arguments["branch"] as? String
    let filesChanged = arguments["filesChanged"] as? [String] ?? []
    let buildPassed = arguments["buildPassed"] as? Bool
    let testsPassed = arguments["testsPassed"] as? Bool

    let mission = MissionService.shared.mission(for: repoPath)

    let reviewPrompt = buildReviewPrompt(
      repoPath: repoPath,
      diff: diff,
      branch: branch,
      filesChanged: filesChanged,
      buildPassed: buildPassed,
      testsPassed: testsPassed,
      mission: mission
    )

    return (200, makeResult(id: id, result: [
      "reviewPrompt": reviewPrompt,
      "expectedOutputFormat": "JSON",
      "instructions": """
        Execute this review prompt and return a JSON object with:
        {
          "verdict": "approve" | "needs_changes" | "rejected",
          "confidence": 0.0-1.0,
          "summary": "one-line summary",
          "categories": {
            "build": { "status": "pass|fail|unknown", "notes": "" },
            "tests": { "status": "pass|fail|unknown", "notes": "" },
            "codeQuality": { "score": 1-5, "issues": [] },
            "security": { "score": 1-5, "issues": [] },
            "missionAlignment": { "aligned": true|false, "reason": "" }
          },
          "issues": [{ "severity": "critical|warning|info", "file": "", "line": 0, "message": "" }],
          "autoMergeRecommended": true|false
        }
        """,
    ]))
  }

  // MARK: - review.confidence

  /// Calculate a confidence score from structured review data.
  private func handleConfidence(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let buildPassed = arguments["buildPassed"] as? Bool ?? false
    let testsPassed = arguments["testsPassed"] as? Bool ?? false
    let codeQualityScore = arguments["codeQualityScore"] as? Int ?? 3
    let securityScore = arguments["securityScore"] as? Int ?? 3
    let missionAligned = arguments["missionAligned"] as? Bool ?? true
    let issueCount = arguments["issueCount"] as? Int ?? 0
    let criticalIssues = arguments["criticalIssues"] as? Int ?? 0

    // Calculate composite confidence
    var confidence: Double = 0.5

    // Build/test pass is a big signal
    if buildPassed { confidence += 0.15 }
    if testsPassed { confidence += 0.15 }

    // Code quality (1-5 scale)
    confidence += Double(min(codeQualityScore, 5)) * 0.04  // 0-0.20

    // Security (1-5 scale) - weighted higher
    confidence += Double(min(securityScore, 5)) * 0.04  // 0-0.20

    // Mission alignment
    if !missionAligned { confidence -= 0.2 }

    // Issues penalty
    if criticalIssues > 0 { confidence = min(confidence, 0.3) }
    confidence -= Double(issueCount) * 0.02

    confidence = max(0.0, min(1.0, confidence))

    let recommendation: String
    if confidence >= 0.85 && criticalIssues == 0 {
      recommendation = "auto-merge"
    } else if confidence >= 0.6 {
      recommendation = "human-review"
    } else {
      recommendation = "reject"
    }

    return (200, makeResult(id: id, result: [
      "confidence": confidence,
      "recommendation": recommendation,
      "factors": [
        "buildPassed": buildPassed,
        "testsPassed": testsPassed,
        "codeQuality": codeQualityScore,
        "security": securityScore,
        "missionAligned": missionAligned,
        "issueCount": issueCount,
        "criticalIssues": criticalIssues,
      ],
    ]))
  }

  // MARK: - Prompt Builder

  private func buildReviewPrompt(
    repoPath: String,
    diff: String,
    branch: String?,
    filesChanged: [String],
    buildPassed: Bool?,
    testsPassed: Bool?,
    mission: String?
  ) -> String {
    var prompt = """
      You are an automated code reviewer for the project at: \(repoPath)
      
      ## Review Criteria
      Evaluate this code change across these dimensions:
      
      ### 1. Build & Tests
      """

    if let buildPassed {
      prompt += "- Build status: \(buildPassed ? "PASSED ✅" : "FAILED ❌")\n"
    } else {
      prompt += "- Build status: Unknown — run the build to check\n"
    }

    if let testsPassed {
      prompt += "- Test status: \(testsPassed ? "PASSED ✅" : "FAILED ❌")\n"
    } else {
      prompt += "- Test status: Unknown — run tests to check\n"
    }

    prompt += """
      
      ### 2. Code Quality
      - Correct use of error handling (no force unwraps, proper guard/do-catch)
      - Follows project patterns and conventions
      - No dead code or commented-out blocks
      - Appropriate use of Swift concurrency (@MainActor, async/await, actors)
      - Code is readable and well-structured
      
      ### 3. Security
      - No hardcoded credentials or API keys
      - No force unwraps in user-facing code paths
      - Proper input validation
      - No unsafe memory operations
      
      ### 4. Mission Alignment
      """

    if let mission {
      prompt += "Project mission:\n\(mission)\n\n"
      prompt += "Verify this change serves the mission.\n"
    } else {
      prompt += "No mission statement found — skip alignment check.\n"
    }

    if let branch {
      prompt += "\n### Branch\n`\(branch)`\n"
    }

    if !filesChanged.isEmpty {
      prompt += "\n### Files Changed (\(filesChanged.count))\n"
      for file in filesChanged.prefix(20) {
        prompt += "- `\(file)`\n"
      }
      if filesChanged.count > 20 {
        prompt += "- ... and \(filesChanged.count - 20) more\n"
      }
    }

    if !diff.isEmpty {
      let truncatedDiff = diff.count > 50_000
        ? String(diff.prefix(50_000)) + "\n\n... [diff truncated at 50K chars]"
        : diff
      prompt += "\n### Diff\n```\n\(truncatedDiff)\n```\n"
    }

    prompt += """
      
      ## Output Format
      Return a JSON object:
      ```json
      {
        "verdict": "approve" | "needs_changes" | "rejected",
        "confidence": 0.0-1.0,
        "summary": "one-line summary of the change",
        "categories": {
          "build": { "status": "pass|fail|unknown", "notes": "..." },
          "tests": { "status": "pass|fail|unknown", "notes": "..." },
          "codeQuality": { "score": 1-5, "issues": ["..."] },
          "security": { "score": 1-5, "issues": ["..."] },
          "missionAlignment": { "aligned": true|false, "reason": "..." }
        },
        "issues": [
          { "severity": "critical|warning|info", "file": "path", "line": 0, "message": "..." }
        ],
        "autoMergeRecommended": true|false
      }
      ```
      
      ## Rules
      - Be constructive — focus on real issues, not style preferences
      - Critical issues: bugs, security vulnerabilities, data loss risks
      - Warnings: force unwraps, missing error handling, deprecated patterns
      - Info: style suggestions, minor improvements
      - confidence >= 0.85 with no critical issues → recommend auto-merge
      - confidence < 0.6 or any critical issue → do not recommend auto-merge
      """

    return prompt
  }

  // MARK: - Tool Definitions

  var toolDefinitions: [[String: Any]] {
    [
      [
        "name": "review.auto",
        "description": "Generate a structured review prompt for a code change. Returns a review prompt with expected JSON output format for build, test, quality, security, and mission alignment checks.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "repoPath": [
              "type": "string",
              "description": "Path to the repository",
            ],
            "diff": [
              "type": "string",
              "description": "The code diff to review",
            ],
            "branch": [
              "type": "string",
              "description": "Branch name for context",
            ],
            "filesChanged": [
              "type": "array",
              "items": ["type": "string"],
              "description": "List of changed file paths",
            ],
            "buildPassed": [
              "type": "boolean",
              "description": "Whether the build passed (if known)",
            ],
            "testsPassed": [
              "type": "boolean",
              "description": "Whether tests passed (if known)",
            ],
          ],
          "required": ["repoPath"],
        ],
      ],
      [
        "name": "review.confidence",
        "description": "Calculate a confidence score and merge recommendation from structured review data. Returns confidence (0-1), recommendation (auto-merge/human-review/reject).",
        "inputSchema": [
          "type": "object",
          "properties": [
            "buildPassed": [
              "type": "boolean",
              "description": "Whether the build passed",
            ],
            "testsPassed": [
              "type": "boolean",
              "description": "Whether tests passed",
            ],
            "codeQualityScore": [
              "type": "integer",
              "description": "Code quality score 1-5",
            ],
            "securityScore": [
              "type": "integer",
              "description": "Security score 1-5",
            ],
            "missionAligned": [
              "type": "boolean",
              "description": "Whether change aligns with mission",
            ],
            "issueCount": [
              "type": "integer",
              "description": "Total number of issues found",
            ],
            "criticalIssues": [
              "type": "integer",
              "description": "Number of critical issues",
            ],
          ],
        ],
      ],
    ]
  }
}
