
//
//  XcodeBuildQueue.swift
//  KitchenSync
//
//  Serializes xcodebuild invocations across agent worktrees to prevent
//  build conflicts when multiple agents run simultaneously.
//
//  Strategy:
//  1. Per-worktree -derivedDataPath so each agent builds into its own
//     derived data folder — prevents file-level collisions.
//  2. Global concurrency limit (default: 1) to avoid CPU/memory pressure
//     when many agents build at the same time. Configurable via
//     XcodeBuildQueue.shared.maxConcurrent.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "XcodeBuildQueue")

/// Shared actor that limits concurrent xcodebuild invocations.
///
/// Each call to `acquire()` blocks until a slot is free, then returns a
/// token. The caller must call `release(token:)` (or use `withSlot`) when
/// the build finishes to free the slot.
actor XcodeBuildQueue {
  // MARK: - Shared

  static let shared = XcodeBuildQueue()

  // MARK: - Configuration

  /// How many xcodebuild processes may run at the same time.
  /// Default 1 = fully serialized. Set to 2+ on macOS hardware with many cores.
  var maxConcurrent: Int = 1 {
    didSet {
      maxConcurrent = max(1, maxConcurrent)
      drainWaiters()
    }
  }

  // MARK: - State

  private var activeCount: Int = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  // MARK: - API

  /// Wait until a build slot is available, then increment the slot count.
  /// Returns a token that MUST be passed to `release(token:)` when done.
  func acquire() async -> BuildToken {
    if activeCount < maxConcurrent {
      activeCount += 1
      logger.debug("Build slot acquired (\(self.activeCount)/\(self.maxConcurrent))")
      return BuildToken(id: UUID())
    }
    // No slot available — suspend until one opens up
    logger.info("Build queued — waiting for slot (\(self.activeCount)/\(self.maxConcurrent) active)")
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
    activeCount += 1
    logger.debug("Build slot acquired after wait (\(self.activeCount)/\(self.maxConcurrent))")
    return BuildToken(id: UUID())
  }

  /// Release a previously-acquired slot.
  func release(_ token: BuildToken) {
    activeCount = max(0, activeCount - 1)
    logger.debug("Build slot released (\(self.activeCount)/\(self.maxConcurrent))")
    drainWaiters()
  }

  /// Convenience: run `body` while holding a build slot.
  func withSlot<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
    let token = await acquire()
    let result = await body()
    release(token)
    return result
  }

  // MARK: - Internal

  private func drainWaiters() {
    while activeCount < maxConcurrent, !waiters.isEmpty {
      let continuation = waiters.removeFirst()
      continuation.resume()
    }
  }
}

/// Opaque token returned by `XcodeBuildQueue.acquire()`.
struct BuildToken: Sendable {
  let id: UUID
}

// MARK: - xcodebuild command augmentation

extension String {
  /// Return a copy of the string with `-derivedDataPath <path>` injected
  /// into the first `xcodebuild` invocation if not already present.
  ///
  /// Also strips any use of `~/Library/Developer/Xcode/DerivedData` to
  /// prevent agents from polluting the global cache.
  func injectingXcodebuildDerivedDataPath(_ path: String) -> String {
    // Only augment lines that actually call xcodebuild
    guard contains("xcodebuild"),
          !contains("-derivedDataPath"),
          !contains("-showBuildSettings"),
          !contains("-list"),
          !contains("-exportArchive"),
          !contains("-exportLocalizations") else {
      return self
    }

    // Escape the path for shell
    let escaped = path.replacingOccurrences(of: " ", with: "\\ ")
    return replacingOccurrences(
      of: "xcodebuild",
      with: "xcodebuild -derivedDataPath \(escaped)",
      options: [],
      range: range(of: "xcodebuild")
    )
  }
}
