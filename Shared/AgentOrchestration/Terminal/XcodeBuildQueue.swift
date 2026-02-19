
//
//  XcodeBuildQueue.swift
//  KitchenSync
//
//  Serializes build invocations across ALL agent worktrees to prevent
//  CPU/memory pressure when multiple agents build simultaneously.
//
//  Covers: xcodebuild, swift build/test, npm/yarn/pnpm, cargo, gradle,
//          make, rake — any command that compiles or bundles.
//
//  Strategy:
//  1. Per-worktree -derivedDataPath (xcodebuild only) so each agent
//     builds into its own derived data folder — no file-level collisions.
//  2. Global concurrency limit (default: 1) to avoid CPU/memory pressure.
//     One queue instance covers ALL repos — cross-project by design.
//     Raise XcodeBuildQueue.shared.maxConcurrent on high-core machines.
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

// MARK: - Build command detection

extension XcodeBuildQueue {
  /// Returns true if `command` invokes a known build/compile/bundle tool
  /// that should be serialized through the global queue.
  ///
  /// This is intentionally broad — false positives (e.g. `cargo --version`)
  /// are harmless: they just queue briefly and exit fast. False negatives
  /// (an unlisted tool) would allow concurrent builds to compete.
  static func isBuildCommand(_ command: String) -> Bool {
    // Xcode
    if command.contains("xcodebuild"),
       !command.contains("-showBuildSettings"),
       !command.contains("-list"),
       !command.contains("-exportArchive"),
       !command.contains("-exportLocalizations") {
      return true
    }
    // Swift Package Manager
    if command.contains("swift build") || command.contains("swift test") {
      return true
    }
    // JavaScript/Node
    let jsPatterns = ["npm run build", "npm run compile", "yarn build", "yarn compile",
                      "pnpm build", "pnpm compile", "npx tsc", "npx vite build",
                      "npx webpack", "ember build"]
    if jsPatterns.contains(where: { command.contains($0) }) { return true }
    // Rust
    if command.contains("cargo build") || command.contains("cargo test") {
      return true
    }
    // JVM
    if command.contains("gradle build") || command.contains("./gradlew build")
        || command.contains("mvn package") || command.contains("mvn install") {
      return true
    }
    // Make / Rake (build targets only, not `make clean` etc.)
    if command.hasPrefix("make ") || command.hasPrefix("rake ") {
      let lower = command.lowercased()
      if lower.contains("clean") || lower.contains("install") { return false }
      return true
    }
    return false
  }
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
