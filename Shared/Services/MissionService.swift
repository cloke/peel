//
//  MissionService.swift
//  Peel
//
//  Loads and caches project mission statements from .peel/mission.md files.
//  Agents reference the mission to stay aligned with project goals.
//

import Foundation

@MainActor
@Observable
public final class MissionService {
  public static let shared = MissionService()

  private var cache: [String: CachedMission] = [:]

  private struct CachedMission {
    let content: String
    let loadedAt: Date
  }

  /// Load the mission statement for a repository, using a short-lived cache.
  public func mission(for repoPath: String) -> String? {
    let cacheKey = repoPath

    // Return cached version if less than 60 seconds old
    if let cached = cache[cacheKey],
       Date().timeIntervalSince(cached.loadedAt) < 60 {
      return cached.content
    }

    let missionPath = (repoPath as NSString).appendingPathComponent(".peel/mission.md")
    guard let content = try? String(contentsOfFile: missionPath, encoding: .utf8),
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    cache[cacheKey] = CachedMission(content: content, loadedAt: Date())
    return content
  }

  /// Build a concise mission context block for injection into agent prompts.
  public func missionPromptBlock(for repoPath: String) -> String? {
    guard let content = mission(for: repoPath) else { return nil }
    return """
    ## Project Mission

    The following mission statement defines what this project is and what work should be prioritized. \
    Reject or flag tasks that don't serve this mission.

    \(content)
    ---
    """
  }

  public func invalidateCache(for repoPath: String) {
    cache.removeValue(forKey: repoPath)
  }
}
