//
//  PersistenceWriter.swift
//  Peel
//
//  Background write-behind from WebRTC events to Firestore.
//  Events are queued locally and flushed periodically for audit and recovery.
//
//  Part of the WebRTC-first networking replan (Plans/NETWORKING_REPLAN.md).
//

import Foundation
import os.log

/// Events that should be persisted to Firestore after RTC delivery.
public enum PersistableEvent: Sendable {
  case taskDispatched(taskId: String, payload: [String: String])
  case taskCompleted(taskId: String, result: [String: String])
  case chatMessage(peerId: String, content: String, timestamp: Date)
  case transferCompleted(peerId: String, repoId: String, bytes: Int, durationMs: Double)
  case connectionEvent(peerId: String, event: String, timestamp: Date)
  case workerStatus(workerId: String, snapshot: [String: String])
}

/// Background write-behind from RTC events to Firestore.
/// Events are queued locally and flushed periodically.
/// The RTC channel is the primary transport — persistence is best-effort.
public actor PersistenceWriter {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "Persistence")

  private var queue: [PersistableEvent] = []
  private var flushTask: Task<Void, Never>?

  /// Callback that writes a batch of events to Firestore.
  /// Injected by the caller (e.g., SwarmCoordinator) to avoid coupling to Firebase.
  private let writeHandler: @Sendable ([PersistableEvent]) async -> Void

  public init(writeHandler: @escaping @Sendable ([PersistableEvent]) async -> Void) {
    self.writeHandler = writeHandler
  }

  /// Enqueue an event for async persistence. Non-blocking.
  public func enqueue(_ event: PersistableEvent) {
    queue.append(event)
  }

  /// Flush all queued events to Firestore.
  public func flush() async {
    guard !queue.isEmpty else { return }
    let batch = queue
    queue.removeAll()

    await writeHandler(batch)
    logger.debug("Flushed \(batch.count) events to Firestore")
  }

  /// Start periodic flushing.
  public func start(interval: Duration = .seconds(5)) {
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self else { break }
        await self.flush()
      }
    }
    logger.info("Persistence writer started (interval: \(interval))")
  }

  /// Stop periodic flushing and flush remaining events.
  public func stop() async {
    flushTask?.cancel()
    flushTask = nil
    await flush()
    logger.info("Persistence writer stopped")
  }
}
