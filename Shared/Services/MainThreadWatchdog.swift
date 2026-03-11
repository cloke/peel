//
//  MainThreadWatchdog.swift
//  Peel
//
//  Detects main thread stalls by pinging from a background thread.
//  Logs warnings when the main thread is blocked for longer than
//  the configured threshold, helping diagnose transient UI freezes
//  during agent chain execution, RAG sync, or SwiftData operations.
//

import Foundation
import os.log

/// Monitors the main thread for stalls and logs diagnostics.
///
/// Usage:
///   MainThreadWatchdog.shared.start()  // call from app launch
///   MainThreadWatchdog.shared.stop()   // call on termination
///
/// The watchdog pings the main thread every `checkInterval` seconds.
/// If the main thread does not respond within `stallThreshold`, a
/// warning is logged with the elapsed time.
final class MainThreadWatchdog: @unchecked Sendable {
  static let shared = MainThreadWatchdog()

  private let logger = Logger(subsystem: "com.peel.diagnostics", category: "MainThreadWatchdog")

  /// How often (seconds) we check the main thread.
  private let checkInterval: TimeInterval = 0.25

  /// How long (seconds) before we consider it a stall.
  private let stallThreshold: TimeInterval = 0.5

  /// Background timer source.
  private var timerSource: DispatchSourceTimer?

  /// Guard against double-start.
  private var running = false

  private init() {}

  func start() {
    guard !running else { return }
    running = true

    let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
    source.schedule(deadline: .now(), repeating: checkInterval)

    source.setEventHandler { [weak self] in
      self?.ping()
    }

    timerSource = source
    source.resume()
    logger.info("Main-thread watchdog started (threshold: \(self.stallThreshold)s)")
  }

  func stop() {
    timerSource?.cancel()
    timerSource = nil
    running = false
    logger.info("Main-thread watchdog stopped")
  }

  // MARK: - Ping

  private func ping() {
    let sentAt = DispatchTime.now()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
      semaphore.signal()
    }

    // Wait up to 2x the stall threshold — if it still doesn't respond, log it.
    let maxWait = stallThreshold * 2
    let result = semaphore.wait(timeout: .now() + maxWait)

    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds) / 1_000_000_000

    switch result {
    case .success:
      if elapsed >= stallThreshold {
        logger.warning("⚠️ Main thread stall: \(String(format: "%.3f", elapsed))s — UI was blocked")
      }
    case .timedOut:
      logger.error("🔴 Main thread BLOCKED for >\(String(format: "%.1f", maxWait))s — possible deadlock or heavy @MainActor work")
    }
  }
}

// MARK: - Scoped Block Timer

/// Logs a warning if a block on the main thread takes too long.
/// Use at known blocking call sites.
///
///   let timer = MainThreadBlockTimer(label: "RAG indexRepository()", logger: myLogger)
///   try await heavyWork()
///   timer.finish()  // logs if over threshold
///
struct MainThreadBlockTimer {
  let label: String
  let logger: Logger
  let threshold: TimeInterval
  private let startTime: DispatchTime

  init(label: String, logger: Logger, threshold: TimeInterval = 0.1) {
    self.label = label
    self.logger = logger
    self.threshold = threshold
    self.startTime = .now()
  }

  func finish() {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
    if elapsed >= threshold {
      let isMainThread = Thread.isMainThread
      logger.warning("⏱ \(self.label): \(String(format: "%.3f", elapsed))s (mainThread=\(isMainThread))")
    }
  }
}
