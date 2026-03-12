//
//  ScheduledChainModels.swift
//  Peel
//
//  SwiftData models for scheduled chain execution (#369).
//  CloudKit-compatible: all properties have defaults, no unique constraints.
//

import Foundation
import SwiftData

// MARK: - Schedule Type

/// How a scheduled chain fires.
enum ScheduleType: String, Codable, Sendable, CaseIterable {
  /// Run every N minutes/hours.
  case interval
  /// Run at a specific time of day (e.g. 02:00).
  case timeOfDay
}

// MARK: - Scheduled Chain

/// A persisted schedule definition that triggers a chain template on a cadence.
@Model
final class ScheduledChain {
  var id: UUID = UUID()

  /// Human-readable name for this schedule (e.g. "Nightly Code Review").
  var name: String = ""

  /// The chain template UUID to run.
  var templateId: String = ""

  /// The chain template name (informational, for display).
  var templateName: String = ""

  /// The prompt to pass to the chain.
  var prompt: String = ""

  /// Repository path the chain targets.
  var repoPath: String = ""

  /// Schedule type: "interval" or "timeOfDay".
  var scheduleTypeRaw: String = "interval"

  /// For interval schedules: interval in seconds between runs.
  var intervalSeconds: Int = 3600

  /// For timeOfDay schedules: hour (0-23) in local time.
  var timeOfDayHour: Int = 2

  /// For timeOfDay schedules: minute (0-59) in local time.
  var timeOfDayMinute: Int = 0

  /// Whether this schedule is active.
  var isEnabled: Bool = true

  /// Skip execution when on battery power.
  var skipOnBattery: Bool = true

  /// Skip execution during Low Power Mode.
  var skipOnLowPower: Bool = true

  /// When this schedule was created.
  var createdAt: Date = Date()

  /// When a chain was last successfully triggered by this schedule.
  var lastRunAt: Date?

  /// The chain run ID from the last execution (for linking to results).
  var lastRunChainId: String?

  /// Whether the last run succeeded.
  var lastRunSucceeded: Bool = false

  /// Error message from the last run, if any.
  var lastRunError: String?

  /// Total number of times this schedule has fired.
  var totalRuns: Int = 0

  /// Total number of successful runs.
  var successfulRuns: Int = 0

  var scheduleType: ScheduleType {
    get { ScheduleType(rawValue: scheduleTypeRaw) ?? .interval }
    set { scheduleTypeRaw = newValue.rawValue }
  }

  init(
    id: UUID = UUID(),
    name: String,
    templateId: String,
    templateName: String,
    prompt: String,
    repoPath: String,
    scheduleType: ScheduleType = .interval,
    intervalSeconds: Int = 3600,
    timeOfDayHour: Int = 2,
    timeOfDayMinute: Int = 0,
    isEnabled: Bool = true,
    skipOnBattery: Bool = true,
    skipOnLowPower: Bool = true
  ) {
    self.id = id
    self.name = name
    self.templateId = templateId
    self.templateName = templateName
    self.prompt = prompt
    self.repoPath = repoPath
    self.scheduleTypeRaw = scheduleType.rawValue
    self.intervalSeconds = intervalSeconds
    self.timeOfDayHour = timeOfDayHour
    self.timeOfDayMinute = timeOfDayMinute
    self.isEnabled = isEnabled
    self.skipOnBattery = skipOnBattery
    self.skipOnLowPower = skipOnLowPower
  }
}

// MARK: - Schedule Run History

/// A record of a single scheduled chain execution.
@Model
final class ScheduledChainRun {
  var id: UUID = UUID()

  /// The schedule that triggered this run.
  var scheduleId: UUID = UUID()

  /// The chain run ID returned by the chain runner.
  var chainRunId: String = ""

  /// Template name (denormalized for display).
  var templateName: String = ""

  /// Whether the run completed successfully.
  var succeeded: Bool = false

  /// Error message if the run failed or was skipped.
  var errorMessage: String?

  /// Reason the run was skipped (e.g. "on battery", "low power").
  var skipReason: String?

  /// When the run started.
  var startedAt: Date = Date()

  /// When the run completed (nil if still running or skipped).
  var completedAt: Date?

  /// Summary of the run result, if available.
  var resultSummary: String?

  init(
    id: UUID = UUID(),
    scheduleId: UUID,
    chainRunId: String = "",
    templateName: String = "",
    succeeded: Bool = false,
    errorMessage: String? = nil,
    skipReason: String? = nil,
    startedAt: Date = Date(),
    completedAt: Date? = nil,
    resultSummary: String? = nil
  ) {
    self.id = id
    self.scheduleId = scheduleId
    self.chainRunId = chainRunId
    self.templateName = templateName
    self.succeeded = succeeded
    self.errorMessage = errorMessage
    self.skipReason = skipReason
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.resultSummary = resultSummary
  }
}
