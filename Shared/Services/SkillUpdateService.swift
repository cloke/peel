//
//  SkillUpdateService.swift
//  Peel
//
//  Service for checking and updating external skill bundles.
//  Issue #263 - Ember skills integration with auto-update checking
//

import Foundation
import SwiftData

/// Service for checking and updating skill bundles from external sources
actor SkillUpdateService {
  
  /// GitHub API base URL
  private let gitHubAPIBase = "https://api.github.com"
  
  /// Repository for ember-best-practices skills
  private let emberSkillsRepo = "NullVoxPopuli/agent-skills"
  private let emberSkillsPath = "skills/ember-best-practices"
  
  /// UserDefaults keys
  private let lastUpdateCheckKey = "peel.skills.lastUpdateCheck"
  private let remoteCommitHashKey = "peel.skills.ember.remoteCommitHash"
  private let updateAvailableKey = "peel.skills.ember.updateAvailable"
  
  /// Minimum interval between update checks (1 hour)
  private let minCheckInterval: TimeInterval = 3600
  
  /// Shared instance
  static let shared = SkillUpdateService()
  
  private init() {}
  
  // MARK: - Update Checking
  
  /// Result of an update check
  struct UpdateCheckResult {
    let hasUpdate: Bool
    let currentVersion: String?
    let latestCommitSHA: String?
    let lastUpdated: Date?
    let error: Error?
  }
  
  /// Check if there's an update available for Ember skills
  /// - Parameter force: Skip the minimum check interval
  /// - Returns: Update check result
  func checkForEmberSkillsUpdate(force: Bool = false) async -> UpdateCheckResult {
    // Check if we should skip due to recent check
    if !force {
      let lastCheck = UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date ?? .distantPast
      if Date().timeIntervalSince(lastCheck) < minCheckInterval {
        let hasUpdate = UserDefaults.standard.bool(forKey: updateAvailableKey)
        let remoteHash = UserDefaults.standard.string(forKey: remoteCommitHashKey)
        return UpdateCheckResult(
          hasUpdate: hasUpdate,
          currentVersion: DefaultSkillsService.loadEmberSkillsBundle()?.meta.version,
          latestCommitSHA: remoteHash,
          lastUpdated: lastCheck,
          error: nil
        )
      }
    }
    
    // Fetch latest commit for the skills path
    do {
      let latestSHA = try await fetchLatestCommitSHA()
      let storedHash = DefaultSkillsService.storedEmberSkillsHash
      let bundle = DefaultSkillsService.loadEmberSkillsBundle()
      
      // Compare with stored hash
      let hasUpdate = storedHash != nil && storedHash != latestSHA
      
      // Store results
      UserDefaults.standard.set(Date(), forKey: lastUpdateCheckKey)
      UserDefaults.standard.set(latestSHA, forKey: remoteCommitHashKey)
      UserDefaults.standard.set(hasUpdate, forKey: updateAvailableKey)
      
      return UpdateCheckResult(
        hasUpdate: hasUpdate,
        currentVersion: bundle?.meta.version,
        latestCommitSHA: latestSHA,
        lastUpdated: Date(),
        error: nil
      )
    } catch {
      print("[SkillUpdateService] Failed to check for updates: \(error)")
      return UpdateCheckResult(
        hasUpdate: false,
        currentVersion: DefaultSkillsService.loadEmberSkillsBundle()?.meta.version,
        latestCommitSHA: nil,
        lastUpdated: nil,
        error: error
      )
    }
  }
  
  /// Fetch the latest commit SHA for the ember-best-practices skill path
  private func fetchLatestCommitSHA() async throws -> String {
    let urlString = "\(gitHubAPIBase)/repos/\(emberSkillsRepo)/commits?path=\(emberSkillsPath)&per_page=1"
    guard let url = URL(string: urlString) else {
      throw SkillUpdateError.invalidURL
    }
    
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
    request.setValue("Peel/1.0", forHTTPHeaderField: "User-Agent")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SkillUpdateError.invalidResponse
    }
    
    guard httpResponse.statusCode == 200 else {
      throw SkillUpdateError.httpError(httpResponse.statusCode)
    }
    
    // Parse the commits array
    guard let commits = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let firstCommit = commits.first,
          let sha = firstCommit["sha"] as? String else {
      throw SkillUpdateError.parseError
    }
    
    return sha
  }
  
  // MARK: - Update Application
  
  /// Update result
  struct UpdateResult {
    let success: Bool
    let skillsUpdated: Int
    let error: Error?
  }
  
  /// Fetch and apply updated Ember skills
  /// - Parameters:
  ///   - context: SwiftData model context
  ///   - repoPath: Path to the Ember repo to update skills for
  /// - Returns: Update result
  func applyEmberSkillsUpdate(context: ModelContext, repoPath: String) async -> UpdateResult {
    // For now, we can only update with bundled skills
    // In the future, this could fetch from GitHub directly
    
    let count = DefaultSkillsService.updateEmberSkills(context: context, repoPath: repoPath)
    
    // Clear update available flag
    UserDefaults.standard.set(false, forKey: updateAvailableKey)
    
    return UpdateResult(
      success: count > 0,
      skillsUpdated: count,
      error: nil
    )
  }
  
  /// Fetch updated skills content from GitHub (for future use)
  /// Currently returns nil - would need to implement AGENTS.md parsing
  func fetchLatestSkillsContent() async throws -> Data? {
    let urlString = "https://raw.githubusercontent.com/\(emberSkillsRepo)/main/\(emberSkillsPath)/AGENTS.md"
    guard let url = URL(string: urlString) else {
      throw SkillUpdateError.invalidURL
    }
    
    var request = URLRequest(url: url)
    request.setValue("Peel/1.0", forHTTPHeaderField: "User-Agent")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
      throw SkillUpdateError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    
    return data
  }
  
  // MARK: - Status
  
  /// Get current update status without making network calls
  func getStoredUpdateStatus() -> (hasUpdate: Bool, lastCheck: Date?, remoteHash: String?) {
    let hasUpdate = UserDefaults.standard.bool(forKey: updateAvailableKey)
    let lastCheck = UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date
    let remoteHash = UserDefaults.standard.string(forKey: remoteCommitHashKey)
    return (hasUpdate, lastCheck, remoteHash)
  }
  
  /// Clear stored update status
  func clearUpdateStatus() {
    UserDefaults.standard.removeObject(forKey: lastUpdateCheckKey)
    UserDefaults.standard.removeObject(forKey: remoteCommitHashKey)
    UserDefaults.standard.removeObject(forKey: updateAvailableKey)
  }
}

// MARK: - Errors

enum SkillUpdateError: LocalizedError {
  case invalidURL
  case invalidResponse
  case httpError(Int)
  case parseError
  case noUpdate
  
  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Invalid URL for skill update check"
    case .invalidResponse:
      return "Invalid response from GitHub API"
    case .httpError(let code):
      return "GitHub API error: HTTP \(code)"
    case .parseError:
      return "Failed to parse GitHub API response"
    case .noUpdate:
      return "No update available"
    }
  }
}
