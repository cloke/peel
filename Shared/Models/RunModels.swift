//
//  RunModels.swift
//  Peel
//
//  Unified Run model types — a "Run" is a Run regardless of whether
//  it's a PR review, local code change, or a long-lived investigation.
//

import Foundation

// MARK: - Run Kind

/// What type of work this run represents
enum RunKind: String, Sendable, CaseIterable {
  case codeChange     // Default: agent implementing a code change
  case prReview       // Reviewing (and optionally fixing) a PR
  case investigation  // Research / analysis with no merge target
  case custom         // User-defined / template-driven
  case managerRun     // Parent run that supervises child runs
}

// MARK: - Run Context (kind-specific metadata)

/// PR-specific context — set when `kind == .prReview`
struct PRRunContext: Sendable {
  let repoOwner: String
  let repoName: String
  let prNumber: Int
  let prTitle: String
  let headRef: String
  var htmlURL: String = ""

  // Review lifecycle
  var reviewChainId: UUID?
  var reviewOutput: String?
  var reviewVerdict: String?  // "approved", "needsChanges", "rejected"
  var reviewModel: String?

  // Fix lifecycle
  var fixChainId: UUID?
  var fixModel: String?

  // Push tracking
  var pushBranch: String?
  var pushResult: String?
  var pushedAt: Date?

  /// The current PR review phase (mirrors PRReviewPhase semantics)
  var phase: String = PRReviewPhase.pending

  /// Serialise to dict for MCP tool responses
  var asDictionary: [String: Any] {
    var d: [String: Any] = [
      "repoOwner": repoOwner,
      "repoName": repoName,
      "prNumber": prNumber,
      "prTitle": prTitle,
      "headRef": headRef,
      "phase": phase,
    ]
    if !htmlURL.isEmpty { d["htmlURL"] = htmlURL }
    if let v = reviewVerdict { d["reviewVerdict"] = v }
    if let v = reviewOutput { d["reviewOutput"] = String(v.prefix(2000)) }
    if let v = reviewModel { d["reviewModel"] = v }
    if let v = pushBranch { d["pushBranch"] = v }
    if let v = pushResult { d["pushResult"] = v }
    return d
  }
}

/// Long-lived idea context — set when the run spans multiple iterations
struct IdeaRunContext: Sendable {
  var iteration: Int = 1
  var notes: String = ""
}
