//
//  NightlyRAGSyncService.swift
//  Peel
//
//  Schedules and manages nightly RAG index snapshot exports.
//  Snapshots are written to ApplicationSupport/Peel/RAG/Snapshots/
//  and trimmed by count, age, and total size.
//

import Foundation
import Observation

@MainActor
@Observable
final class NightlyRAGSyncService {

  static let shared = NightlyRAGSyncService()

  // MARK: - Persisted Settings (UserDefaults)

  private enum Keys {
    static let enabled = "rag.nightly.enabled"
    static let hourUTC = "rag.nightly.hourUTC"
    static let maxSnapshots = "rag.nightly.maxSnapshots"
    static let maxTotalMB = "rag.nightly.maxTotalMB"
    static let lastRunAt = "rag.nightly.lastRunAt"
  }

  var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: Keys.enabled) }
    set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
  }

  /// Local hour (0–23) at which to run the nightly export. Default: 2 (2 AM).
  var scheduleHour: Int {
    get {
      let v = UserDefaults.standard.integer(forKey: Keys.hourUTC)
      return v == 0 && !UserDefaults.standard.contains(key: Keys.hourUTC) ? 2 : v
    }
    set { UserDefaults.standard.set(newValue, forKey: Keys.hourUTC) }
  }

  /// Maximum number of snapshots to keep. Default: 7.
  var maxSnapshots: Int {
    get {
      let v = UserDefaults.standard.integer(forKey: Keys.maxSnapshots)
      return v == 0 ? 7 : v
    }
    set { UserDefaults.standard.set(max(1, newValue), forKey: Keys.maxSnapshots) }
  }

  /// Maximum total size of all snapshots in megabytes. Default: 2048 (2 GB).
  var maxTotalSizeMB: Int {
    get {
      let v = UserDefaults.standard.integer(forKey: Keys.maxTotalMB)
      return v == 0 ? 2048 : v
    }
    set { UserDefaults.standard.set(max(1, newValue), forKey: Keys.maxTotalMB) }
  }

  var lastRunAt: Date? {
    get { UserDefaults.standard.object(forKey: Keys.lastRunAt) as? Date }
    set { UserDefaults.standard.set(newValue, forKey: Keys.lastRunAt) }
  }

  var nextRunAt: Date? { computeNextRunDate() }

  var isRunning = false
  var lastError: String?

  // MARK: - Private

  private var scheduledTimer: Timer?
  private weak var mcpServerRef: MCPServerService?

  // MARK: - Init

  private init() {}

  // MARK: - Scheduling

  func enable(mcpServer: MCPServerService) {
    isEnabled = true
    mcpServerRef = mcpServer
    scheduleNextRun()
  }

  func enable() {
    isEnabled = true
    scheduleNextRun()
  }

  func disable() {
    isEnabled = false
    scheduledTimer?.invalidate()
    scheduledTimer = nil
  }

  private func scheduleNextRun() {
    scheduledTimer?.invalidate()
    scheduledTimer = nil
    guard let nextDate = computeNextRunDate() else { return }
    let delay = nextDate.timeIntervalSinceNow
    guard delay > 0 else { return }
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.runIfEnabled()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    scheduledTimer = timer
  }

  private func runIfEnabled() {
    guard isEnabled, let mcpServer = mcpServerRef else {
      scheduleNextTimer24h()
      return
    }
    Task {
      try? await runExport(mcpServer: mcpServer)
      scheduleNextTimer24h()
    }
  }

  /// Schedule the repeating 24h timer after the first fire.
  private func scheduleNextTimer24h() {
    scheduledTimer?.invalidate()
    let timer = Timer(timeInterval: 86400, repeats: true) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.runIfEnabled()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    scheduledTimer = timer
  }

  private func computeNextRunDate() -> Date? {
    var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    components.hour = scheduleHour
    components.minute = 0
    components.second = 0
    guard var candidate = Calendar.current.date(from: components) else { return nil }
    if candidate <= Date() {
      candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }
    return candidate
  }

  // MARK: - Export

  func runExport(mcpServer: MCPServerService) async throws {
    guard !isRunning else { return }
    isRunning = true
    lastError = nil
    defer { isRunning = false }

    do {
      let ragStore = mcpServer.localRagStore
      let status = await ragStore.status()
      let stats = try? await ragStore.stats()
      let repos = (try? await ragStore.listRepos()) ?? []

      let bundle = try await LocalRAGArtifacts.createBundle(status: status, stats: stats, repos: repos)

      let snapshotsDir = snapshotsDirectory()
      try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

      let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
      let destZip = snapshotsDir.appendingPathComponent("snapshot-\(timestamp).zip")
      try FileManager.default.copyItem(at: bundle.bundleURL, to: destZip)

      // Write manifest alongside the zip
      let manifestURL = snapshotsDir.appendingPathComponent("snapshot-\(timestamp)-manifest.json")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let manifestData = try encoder.encode(bundle.manifest)
      try manifestData.write(to: manifestURL, options: .atomic)

      // Clean up the temporary bundle
      try? FileManager.default.removeItem(at: bundle.bundleURL)

      lastRunAt = Date()
      applySnapshotRetentionPolicy()
    } catch {
      lastError = error.localizedDescription
      throw error
    }
  }

  // MARK: - Retention Policy

  func applySnapshotRetentionPolicy() {
    let dir = snapshotsDirectory()
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: .skipsHiddenFiles
    ) else { return }

    let zips = entries
      .filter { $0.pathExtension == "zip" }
      .compactMap { url -> (url: URL, date: Date, size: Int)? in
        let attrs = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        guard let date = attrs?.creationDate else { return nil }
        let size = attrs?.fileSize ?? 0
        return (url: url, date: date, size: size)
      }
      .sorted { $0.date > $1.date }

    let cutoff = Date().addingTimeInterval(-30 * 86400)
    var totalBytes = 0
    let maxBytes = maxTotalSizeMB * 1024 * 1024

    for (index, entry) in zips.enumerated() {
      let shouldRemove = index >= maxSnapshots || entry.date < cutoff || totalBytes + entry.size > maxBytes
      if shouldRemove {
        try? FileManager.default.removeItem(at: entry.url)
        // Remove paired manifest if present
        let manifestURL = entry.url.deletingPathExtension().appendingPathExtension("").appendingPathComponent("")
        let manifestCandidate = entry.url.deletingLastPathComponent()
          .appendingPathComponent(entry.url.deletingPathExtension().lastPathComponent + "-manifest.json")
        try? FileManager.default.removeItem(at: manifestCandidate)
      } else {
        totalBytes += entry.size
      }
    }
  }

  // MARK: - Helpers

  private func snapshotsDirectory() -> URL {
    LocalRAGArtifacts.ragBaseURL().appendingPathComponent("Snapshots", isDirectory: true)
  }
}

// MARK: - UserDefaults helper

private extension UserDefaults {
  func contains(key: String) -> Bool {
    object(forKey: key) != nil
  }
}
