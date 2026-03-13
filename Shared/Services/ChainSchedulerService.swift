//
//  ChainSchedulerService.swift
//  Peel
//
//  Cron-like scheduler that triggers agent chain execution on a schedule (#369).
//  Supports interval-based and time-of-day schedules, with power-aware skipping
//  and local notification on completion.
//

import Foundation
import OSLog
import SwiftData
import UserNotifications
import IOKit.ps

// MARK: - Delegate

@MainActor
protocol ChainSchedulerDelegate: AnyObject {
  /// Start a chain from a schedule. Returns the chain run ID.
  func schedulerStartChain(
    prompt: String,
    repoPath: String,
    templateId: String?,
    templateName: String?
  ) async throws -> String

  /// Log an info message through the MCP log system.
  func schedulerLog(_ message: String, metadata: [String: String])
}

// MARK: - ChainSchedulerService

@MainActor
@Observable
final class ChainSchedulerService {
  private let logger = Logger(subsystem: "com.peel.services", category: "ChainScheduler")

  // MARK: - Dependencies

  weak var delegate: ChainSchedulerDelegate?
  private var modelContext: ModelContext?

  // MARK: - Observable State

  /// Whether the scheduler is actively checking for due schedules.
  private(set) var isActive = false

  /// How often the scheduler checks for due schedules (default: 60 seconds).
  var checkIntervalSeconds: TimeInterval = 60

  /// Whether a check cycle is currently in progress.
  private(set) var isChecking = false

  /// Number of active schedules.
  private(set) var activeScheduleCount = 0

  // MARK: - Private

  private var timerTask: Task<Void, Never>?

  // MARK: - Lifecycle

  func configure(modelContext: ModelContext) {
    self.modelContext = modelContext
    refreshActiveCount()
  }

  func start() {
    guard !isActive else { return }
    guard modelContext != nil else {
      logger.warning("Cannot start ChainSchedulerService: modelContext not set")
      return
    }

    isActive = true
    logger.info("ChainSchedulerService started (check interval: \(self.checkIntervalSeconds)s)")

    timerTask = Task { [weak self] in
      // Initial check after a short delay to let the app settle
      try? await Task.sleep(for: .seconds(15))
      await self?.checkDueSchedules()

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(self?.checkIntervalSeconds ?? 60))
        guard !Task.isCancelled else { break }
        await self?.checkDueSchedules()
      }
    }
  }

  func stop() {
    timerTask?.cancel()
    timerTask = nil
    isActive = false
    logger.info("ChainSchedulerService stopped")
  }

  // MARK: - Schedule Management

  func createSchedule(
    name: String,
    templateId: String,
    templateName: String,
    prompt: String,
    repoPath: String,
    scheduleType: ScheduleType = .interval,
    intervalSeconds: Int = 3600,
    timeOfDayHour: Int = 2,
    timeOfDayMinute: Int = 0,
    skipOnBattery: Bool = true,
    skipOnLowPower: Bool = true
  ) throws -> ScheduledChain {
    guard let ctx = modelContext else {
      throw SchedulerError.notConfigured
    }

    let schedule = ScheduledChain(
      name: name,
      templateId: templateId,
      templateName: templateName,
      prompt: prompt,
      repoPath: repoPath,
      scheduleType: scheduleType,
      intervalSeconds: intervalSeconds,
      timeOfDayHour: timeOfDayHour,
      timeOfDayMinute: timeOfDayMinute,
      skipOnBattery: skipOnBattery,
      skipOnLowPower: skipOnLowPower
    )

    ctx.insert(schedule)
    try ctx.save()
    refreshActiveCount()

    logger.info("Created schedule '\(name)' (\(scheduleType.rawValue))")
    return schedule
  }

  func deleteSchedule(id: UUID) throws {
    guard let ctx = modelContext else {
      throw SchedulerError.notConfigured
    }

    let predicate = #Predicate<ScheduledChain> { $0.id == id }
    let descriptor = FetchDescriptor<ScheduledChain>(predicate: predicate)
    guard let schedule = try ctx.fetch(descriptor).first else {
      throw SchedulerError.notFound
    }

    ctx.delete(schedule)
    try ctx.save()
    refreshActiveCount()
  }

  func updateSchedule(
    id: UUID,
    name: String? = nil,
    isEnabled: Bool? = nil,
    prompt: String? = nil,
    intervalSeconds: Int? = nil,
    timeOfDayHour: Int? = nil,
    timeOfDayMinute: Int? = nil,
    skipOnBattery: Bool? = nil,
    skipOnLowPower: Bool? = nil
  ) throws -> ScheduledChain {
    guard let ctx = modelContext else {
      throw SchedulerError.notConfigured
    }

    let predicate = #Predicate<ScheduledChain> { $0.id == id }
    let descriptor = FetchDescriptor<ScheduledChain>(predicate: predicate)
    guard let schedule = try ctx.fetch(descriptor).first else {
      throw SchedulerError.notFound
    }

    if let name { schedule.name = name }
    if let isEnabled { schedule.isEnabled = isEnabled }
    if let prompt { schedule.prompt = prompt }
    if let intervalSeconds { schedule.intervalSeconds = intervalSeconds }
    if let timeOfDayHour { schedule.timeOfDayHour = timeOfDayHour }
    if let timeOfDayMinute { schedule.timeOfDayMinute = timeOfDayMinute }
    if let skipOnBattery { schedule.skipOnBattery = skipOnBattery }
    if let skipOnLowPower { schedule.skipOnLowPower = skipOnLowPower }

    try ctx.save()
    refreshActiveCount()
    return schedule
  }

  func listSchedules() -> [ScheduledChain] {
    guard let ctx = modelContext else { return [] }
    let descriptor = FetchDescriptor<ScheduledChain>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    return (try? ctx.fetch(descriptor)) ?? []
  }

  func getSchedule(id: UUID) -> ScheduledChain? {
    guard let ctx = modelContext else { return nil }
    let predicate = #Predicate<ScheduledChain> { $0.id == id }
    let descriptor = FetchDescriptor<ScheduledChain>(predicate: predicate)
    return try? ctx.fetch(descriptor).first
  }

  func listRunHistory(scheduleId: UUID? = nil, limit: Int = 50) -> [ScheduledChainRun] {
    guard let ctx = modelContext else { return [] }
    var descriptor = FetchDescriptor<ScheduledChainRun>(
      sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
    )
    if let scheduleId {
      descriptor.predicate = #Predicate<ScheduledChainRun> { $0.scheduleId == scheduleId }
    }
    descriptor.fetchLimit = limit
    return (try? ctx.fetch(descriptor)) ?? []
  }

  // MARK: - Schedule Evaluation

  private func checkDueSchedules() async {
    guard let ctx = modelContext, delegate != nil else { return }
    guard !isChecking else {
      logger.debug("Schedule check already in progress, skipping")
      return
    }

    isChecking = true
    defer { isChecking = false }

    let enabledPredicate = #Predicate<ScheduledChain> { $0.isEnabled == true }
    let descriptor = FetchDescriptor<ScheduledChain>(predicate: enabledPredicate)
    guard let schedules = try? ctx.fetch(descriptor), !schedules.isEmpty else {
      return
    }

    let now = Date()

    for schedule in schedules {
      guard isDue(schedule, at: now) else { continue }

      // Power checks
      if let skipReason = powerSkipReason(for: schedule) {
        recordSkippedRun(schedule: schedule, reason: skipReason)
        delegate?.schedulerLog("Skipped schedule '\(schedule.name)'", metadata: [
          "reason": skipReason,
          "scheduleId": schedule.id.uuidString
        ])
        continue
      }

      await executeSchedule(schedule)
    }
  }

  private func isDue(_ schedule: ScheduledChain, at now: Date) -> Bool {
    switch schedule.scheduleType {
    case .interval:
      guard let lastRun = schedule.lastRunAt else {
        // Never run — due immediately
        return true
      }
      return now.timeIntervalSince(lastRun) >= Double(schedule.intervalSeconds)

    case .timeOfDay:
      let calendar = Calendar.current
      let components = calendar.dateComponents([.hour, .minute], from: now)
      let currentHour = components.hour ?? 0
      let currentMinute = components.minute ?? 0

      // Check if we're in the target time window (within check interval)
      let targetMinutes = schedule.timeOfDayHour * 60 + schedule.timeOfDayMinute
      let currentMinutes = currentHour * 60 + currentMinute
      let windowMinutes = Int(checkIntervalSeconds / 60) + 1

      guard abs(currentMinutes - targetMinutes) <= windowMinutes else {
        return false
      }

      // Don't fire if already ran today
      if let lastRun = schedule.lastRunAt {
        return !calendar.isDate(lastRun, inSameDayAs: now)
      }
      return true
    }
  }

  // MARK: - Power Awareness

  private func powerSkipReason(for schedule: ScheduledChain) -> String? {
    if schedule.skipOnBattery && isOnBattery() {
      return "on battery"
    }
    if schedule.skipOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
      return "low power mode"
    }
    return nil
  }

  private func isOnBattery() -> Bool {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let type = IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as String
    return type == kIOPSBatteryPowerValue as String
  }

  // MARK: - Execution

  private func executeSchedule(_ schedule: ScheduledChain) async {
    guard let delegate, let ctx = modelContext else { return }

    let runRecord = ScheduledChainRun(
      scheduleId: schedule.id,
      templateName: schedule.templateName,
      startedAt: Date()
    )
    ctx.insert(runRecord)

    schedule.lastRunAt = Date()
    schedule.totalRuns += 1

    delegate.schedulerLog("Executing schedule '\(schedule.name)'", metadata: [
      "scheduleId": schedule.id.uuidString,
      "templateName": schedule.templateName,
      "totalRuns": "\(schedule.totalRuns)"
    ])

    do {
      let chainRunId = try await delegate.schedulerStartChain(
        prompt: schedule.prompt,
        repoPath: schedule.repoPath,
        templateId: schedule.templateId,
        templateName: nil
      )

      runRecord.chainRunId = chainRunId
      runRecord.succeeded = true
      runRecord.completedAt = Date()
      schedule.lastRunChainId = chainRunId
      schedule.lastRunSucceeded = true
      schedule.lastRunError = nil
      schedule.successfulRuns += 1

      try? ctx.save()

      await sendNotification(
        title: "Schedule completed: \(schedule.name)",
        body: "Chain started successfully (\(schedule.templateName))"
      )

      delegate.schedulerLog("Schedule '\(schedule.name)' chain started", metadata: [
        "chainRunId": chainRunId,
        "scheduleId": schedule.id.uuidString
      ])
    } catch {
      runRecord.succeeded = false
      runRecord.errorMessage = error.localizedDescription
      runRecord.completedAt = Date()
      schedule.lastRunSucceeded = false
      schedule.lastRunError = error.localizedDescription

      try? ctx.save()

      await sendNotification(
        title: "Schedule failed: \(schedule.name)",
        body: error.localizedDescription
      )

      logger.error("Schedule '\(schedule.name)' failed: \(error.localizedDescription)")
    }

    refreshActiveCount()
  }

  private func recordSkippedRun(schedule: ScheduledChain, reason: String) {
    guard let ctx = modelContext else { return }

    let runRecord = ScheduledChainRun(
      scheduleId: schedule.id,
      templateName: schedule.templateName,
      skipReason: reason,
      startedAt: Date(),
      completedAt: Date()
    )
    ctx.insert(runRecord)
    try? ctx.save()
  }

  // MARK: - Notifications

  private func sendNotification(title: String, body: String) async {
    let center = UNUserNotificationCenter.current()

    // Request permission if needed (no-op if already granted)
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    guard await center.notificationSettings().authorizationStatus == .authorized else {
      return
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil // Deliver immediately
    )

    try? await center.add(request)
  }

  // MARK: - Helpers

  private func refreshActiveCount() {
    guard let ctx = modelContext else {
      activeScheduleCount = 0
      return
    }
    let enabledPredicate = #Predicate<ScheduledChain> { $0.isEnabled == true }
    let descriptor = FetchDescriptor<ScheduledChain>(predicate: enabledPredicate)
    activeScheduleCount = (try? ctx.fetchCount(descriptor)) ?? 0
  }
}

// MARK: - Errors

enum SchedulerError: LocalizedError {
  case notConfigured
  case notFound

  var errorDescription: String? {
    switch self {
    case .notConfigured: "Scheduler not configured (no model context)"
    case .notFound: "Schedule not found"
    }
  }
}
