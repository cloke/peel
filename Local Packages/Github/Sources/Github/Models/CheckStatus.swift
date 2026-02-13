//
//  CheckStatus.swift
//  Github
//
//  Models for GitHub commit status and check runs
//

import Foundation

extension Github {
  /// Combined commit status from the GitHub Status API
  public struct CombinedStatus: Codable {
    public let state: String // success, failure, pending, error
    public let statuses: [CommitStatus]
    public let total_count: Int
  }

  public struct CommitStatus: Codable, Identifiable {
    public var id: Int
    public let state: String // success, failure, pending, error
    public let context: String
    public let description: String?
    public let target_url: String?
    public let created_at: String?
  }

  /// Check suites response from the GitHub Check Runs API
  public struct CheckRunsResponse: Codable {
    public let total_count: Int
    public let check_runs: [CheckRun]
  }

  public struct CheckRun: Codable, Identifiable {
    public var id: Int
    public let name: String
    public let status: String // queued, in_progress, completed
    public let conclusion: String? // success, failure, neutral, cancelled, timed_out, action_required, skipped
    public let html_url: String?
    public let started_at: String?
    public let completed_at: String?
  }

  /// Aggregated check status for display
  public struct AggregatedCheckStatus: Sendable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    public let pending: Int
    public let checks: [CheckItem]

    public var overallState: OverallState {
      if total == 0 { return .none }
      if failed > 0 { return .failure }
      if pending > 0 { return .pending }
      return .success
    }

    public enum OverallState: Sendable {
      case success, failure, pending, none
    }
  }

  public struct CheckItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let state: CheckItemState
    public let url: String?
  }

  public enum CheckItemState: Sendable {
    case success, failure, pending, neutral, skipped
  }
}
