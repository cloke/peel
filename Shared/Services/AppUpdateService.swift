import Foundation
import os
#if os(macOS)
import AppKit
#endif

/// Checks for new Peel releases on GitHub and coordinates download + install.
/// macOS only — iOS updates go through TestFlight / App Store.
actor AppUpdateService {
  static let shared = AppUpdateService()

  private let logger = Logger(subsystem: "com.crunchy-bananas.Peel", category: "AppUpdate")
  private let repo = "cloke/peel"
  private let checkIntervalKey = "peel.update.lastCheck"
  private let skippedVersionKey = "peel.update.skippedVersion"
  private let checkFrequencyKey = "peel.update.checkFrequency"

  // MARK: - Models

  struct UpdateInfo: Sendable {
    let version: String
    let tagName: String
    let commitHash: String?
    let downloadURL: URL
    let releaseNotes: String
    let publishedAt: Date?
    let assetSize: Int64
  }

  enum UpdateState: Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateInfo)
    case downloading(progress: Double)
    case installing
    case error(String)
  }

  enum CheckFrequency: Int, CaseIterable, Sendable {
    case daily = 86_400
    case weekly = 604_800
    case never = 0

    var label: String {
      switch self {
      case .daily: "Daily"
      case .weekly: "Weekly"
      case .never: "Never"
      }
    }
  }

  /// Current check frequency preference.
  var checkFrequency: CheckFrequency {
    let raw = UserDefaults.standard.integer(forKey: checkFrequencyKey)
    return CheckFrequency(rawValue: raw) ?? .daily
  }

  // MARK: - Check for Updates

  /// Check GitHub Releases for a newer version.
  /// - Parameter force: Bypass throttle and skip-version.
  func checkForUpdate(force: Bool = false) async -> UpdateState {
    let frequency = checkFrequency
    if !force {
      if frequency == .never {
        logger.debug("Automatic update checks disabled")
        return .idle
      }
      let lastCheck = UserDefaults.standard.object(forKey: checkIntervalKey) as? Date ?? .distantPast
      if Date().timeIntervalSince(lastCheck) < Double(frequency.rawValue) {
        logger.debug("Skipping update check — last check was recent")
        return .upToDate
      }
    }

    logger.info("Checking for updates…")

    do {
      let release = try await fetchLatestRelease()
      await MainActor.run {
        UserDefaults.standard.set(Date(), forKey: checkIntervalKey)
      }

      let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
      let remoteVersion = release.version

      if compareVersions(remoteVersion, isNewerThan: currentVersion) {
        let skipped = UserDefaults.standard.string(forKey: skippedVersionKey)
        if !force && skipped == remoteVersion {
          logger.info("Version \(remoteVersion) was skipped by user")
          return .upToDate
        }
        logger.info("Update available: \(remoteVersion) (current: \(currentVersion))")
        return .available(release)
      } else {
        logger.info("Up to date (\(currentVersion))")
        return .upToDate
      }
    } catch {
      logger.error("Update check failed: \(error.localizedDescription)")
      return .error(error.localizedDescription)
    }
  }

  /// Mark a version as skipped so the user isn't prompted again.
  func skipVersion(_ version: String) {
    UserDefaults.standard.set(version, forKey: skippedVersionKey)
  }

  // MARK: - GitHub API

  private func fetchLatestRelease() async throws -> UpdateInfo {
    let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
    guard let url = URL(string: urlString) else {
      throw UpdateError.invalidURL
    }

    var request = URLRequest(url: url)
    request.addValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.addValue("Peel-UpdateChecker", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw UpdateError.apiError(statusCode: statusCode)
    }

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

    guard let tagName = json["tag_name"] as? String else {
      throw UpdateError.missingTag
    }

    let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

    // Find the macOS zip asset
    let assets = json["assets"] as? [[String: Any]] ?? []
    guard let macAsset = assets.first(where: { ($0["name"] as? String ?? "").contains("macos") }),
          let downloadURLString = macAsset["browser_download_url"] as? String,
          let downloadURL = URL(string: downloadURLString) else {
      throw UpdateError.noMacOSAsset
    }

    // Validate the download URL points to the expected GitHub domain
    guard downloadURL.host?.hasSuffix("github.com") == true
            || downloadURL.host?.hasSuffix("githubusercontent.com") == true else {
      throw UpdateError.untrustedURL
    }

    let assetSize = macAsset["size"] as? Int64 ?? 0
    let body = json["body"] as? String ?? ""
    let publishedStr = json["published_at"] as? String
    let publishedAt = publishedStr.flatMap { ISO8601DateFormatter().date(from: $0) }

    return UpdateInfo(
      version: version,
      tagName: tagName,
      commitHash: nil,
      downloadURL: downloadURL,
      releaseNotes: body,
      publishedAt: publishedAt,
      assetSize: assetSize
    )
  }

  // MARK: - Download

  /// Download the update zip with progress reporting.
  /// - Parameters:
  ///   - info: The release info containing the download URL.
  ///   - onProgress: Called with download progress (0.0–1.0).
  /// - Returns: Local file URL of the downloaded zip.
  func downloadUpdate(_ info: UpdateInfo, onProgress: @Sendable @escaping (Double) -> Void) async throws -> URL {
    let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Peel")
      .appendingPathComponent("Updates")
    try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

    let destURL = appSupportDir.appendingPathComponent("Peel-\(info.tagName)-macos.zip")

    // Remove any previous download
    try? FileManager.default.removeItem(at: destURL)

    logger.info("Downloading update from \(info.downloadURL.absoluteString)")

    let (asyncBytes, response) = try await URLSession.shared.bytes(from: info.downloadURL)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw UpdateError.downloadFailed(statusCode: code)
    }

    let expectedLength = http.expectedContentLength
    var downloadedData = Data()
    downloadedData.reserveCapacity(expectedLength > 0 ? Int(expectedLength) : 50_000_000)

    var lastReportedProgress = 0.0
    for try await byte in asyncBytes {
      downloadedData.append(byte)
      if expectedLength > 0 {
        let progress = Double(downloadedData.count) / Double(expectedLength)
        // Report progress in 1% increments to avoid flooding
        if progress - lastReportedProgress >= 0.01 {
          lastReportedProgress = progress
          onProgress(progress)
        }
      }
    }

    // Verify size if known
    if info.assetSize > 0 && Int64(downloadedData.count) != info.assetSize {
      logger.error("Size mismatch: expected \(info.assetSize), got \(downloadedData.count)")
      throw UpdateError.sizeMismatch(expected: info.assetSize, actual: Int64(downloadedData.count))
    }

    try downloadedData.write(to: destURL)
    onProgress(1.0)
    logger.info("Downloaded \(downloadedData.count) bytes to \(destURL.path)")
    return destURL
  }

  // MARK: - Install

  /// Unzip the update, replace the running app, and relaunch.
  #if os(macOS)
  func installUpdate(from zipURL: URL) async throws {
    let fm = FileManager.default
    let currentAppURL = Bundle.main.bundleURL

    // 1. Unzip to a temp directory next to the zip
    let unzipDir = zipURL.deletingLastPathComponent().appendingPathComponent("Peel-unzip-\(UUID().uuidString)")
    try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)

    logger.info("Unzipping to \(unzipDir.path)")
    let unzipProcess = Process()
    unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzipProcess.arguments = ["-x", "-k", zipURL.path, unzipDir.path]
    try unzipProcess.run()
    unzipProcess.waitUntilExit()

    guard unzipProcess.terminationStatus == 0 else {
      throw UpdateError.unzipFailed
    }

    // 2. Find the .app in the unzipped contents
    let contents = try fm.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)
    guard let newAppURL = contents.first(where: { $0.pathExtension == "app" }) else {
      throw UpdateError.noAppInZip
    }

    // 3. Verify the new app has a valid bundle identifier
    guard let newBundle = Bundle(url: newAppURL),
          let newBundleID = newBundle.bundleIdentifier,
          newBundleID == Bundle.main.bundleIdentifier else {
      throw UpdateError.bundleMismatch
    }

    // 4. Create a backup of the current app
    let backupURL = currentAppURL.deletingLastPathComponent()
      .appendingPathComponent("Peel-backup-\(UUID().uuidString).app")
    logger.info("Backing up current app to \(backupURL.path)")
    try fm.moveItem(at: currentAppURL, to: backupURL)

    // 5. Move new app into place
    do {
      try fm.moveItem(at: newAppURL, to: currentAppURL)
    } catch {
      // Restore backup on failure
      logger.error("Failed to place new app, restoring backup: \(error)")
      try? fm.moveItem(at: backupURL, to: currentAppURL)
      throw UpdateError.installFailed(error.localizedDescription)
    }

    // 6. Cleanup
    try? fm.removeItem(at: backupURL)
    try? fm.removeItem(at: unzipDir)
    try? fm.removeItem(at: zipURL)

    logger.info("Update installed successfully, relaunching...")

    // 7. Relaunch
    await relaunch()
  }

  @MainActor
  private func relaunch() {
    let appURL = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true

    // Launch new instance then terminate this one
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
      if let error {
        NSLog("Failed to relaunch: \(error)")
      }
    }

    // Give the new instance a moment to start, then exit
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      NSApp.terminate(nil)
    }
  }
  #endif

  // MARK: - Version Comparison

  /// Simple semantic version comparison: "1.3.0" > "1.2.0"
  func compareVersions(_ remote: String, isNewerThan local: String) -> Bool {
    let r = remote.split(separator: ".").compactMap { Int($0) }
    let l = local.split(separator: ".").compactMap { Int($0) }
    let count = max(r.count, l.count)
    for i in 0..<count {
      let rv = i < r.count ? r[i] : 0
      let lv = i < l.count ? l[i] : 0
      if rv > lv { return true }
      if rv < lv { return false }
    }
    return false
  }

  // MARK: - Errors

  enum UpdateError: LocalizedError {
    case invalidURL
    case apiError(statusCode: Int)
    case missingTag
    case noMacOSAsset
    case untrustedURL
    case downloadFailed(statusCode: Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case unzipFailed
    case noAppInZip
    case bundleMismatch
    case installFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidURL: "Invalid GitHub API URL"
      case .apiError(let code): "GitHub API returned status \(code)"
      case .missingTag: "Release has no tag"
      case .noMacOSAsset: "No macOS asset found in release"
      case .untrustedURL: "Download URL is not from a trusted GitHub domain"
      case .downloadFailed(let code): "Download failed with status \(code)"
      case .sizeMismatch(let expected, let actual): "File size mismatch: expected \(expected) bytes, got \(actual)"
      case .unzipFailed: "Failed to unzip update"
      case .noAppInZip: "No .app bundle found in download"
      case .bundleMismatch: "Downloaded app has wrong bundle identifier"
      case .installFailed(let reason): "Install failed: \(reason)"
      }
    }
  }
}
