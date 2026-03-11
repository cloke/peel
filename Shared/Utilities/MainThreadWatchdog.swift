import Foundation
import os.log

// MARK: - MainThreadWatchdog

/// Periodically pings the main queue to detect stalls in DEBUG builds.
/// Start once at app launch via `MainThreadWatchdog.shared.start()`.
final class MainThreadWatchdog: @unchecked Sendable {
  static let shared = MainThreadWatchdog()

  private let interval: TimeInterval = 1.0
  private let stallThreshold: TimeInterval = 0.5
  private let queue = DispatchQueue(label: "com.peel.watchdog", qos: .utility)
  private let logger = Logger(subsystem: "com.peel.diagnostics", category: "MainThreadWatchdog")
  private var timer: DispatchSourceTimer?

  private init() {}

  func start() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + interval, repeating: interval)
    t.setEventHandler { [weak self] in self?.ping() }
    t.resume()
    timer = t
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  private func ping() {
    let sent = Date()
    DispatchQueue.main.async { [weak self, sent] in
      let delay = Date().timeIntervalSince(sent)
      if delay > (self?.stallThreshold ?? 0.5) {
        self?.logger.warning("Main thread stall detected: \(String(format: "%.2f", delay))s")
      }
    }
  }
}

// MARK: - MainThreadBlockTimer

/// Times a potentially-blocking operation and warns if finish() is not called promptly.
final class MainThreadBlockTimer: @unchecked Sendable {
  private let label: String
  private let logger: Logger
  private let start: Date
  private let warnAfter: TimeInterval
  private let queue = DispatchQueue(label: "com.peel.blocktimer", qos: .utility)
  private var workItem: DispatchWorkItem?
  private var finished = false

  init(
    label labelValue: String,
    logger loggerValue: Logger,
    warnAfter warnAfterValue: TimeInterval = 1.0
  ) {
    self.label = labelValue
    self.logger = loggerValue
    self.start = Date()
    self.warnAfter = warnAfterValue

    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.finished else { return }
      self.logger.warning("[\(self.label)] still running after \(String(format: "%.1f", self.warnAfter))s — possible main thread block")
    }
    workItem = item
    queue.asyncAfter(deadline: .now() + warnAfterValue, execute: item)
  }

  func finish() {
    finished = true
    workItem?.cancel()
    workItem = nil
    let elapsed = Date().timeIntervalSince(self.start)
    self.logger.debug("[\(self.label)] completed in \(String(format: "%.3f", elapsed))s")
  }
}
