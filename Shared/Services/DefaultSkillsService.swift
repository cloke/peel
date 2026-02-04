//
//  DefaultSkillsService.swift
//  Peel
//
//  Loads default repo guidance skills on first launch.
//  Issue #90, #263 (Ember skills integration)
//

import Foundation
import SwiftData
import CryptoKit

/// Service for seeding default repo guidance skills
enum DefaultSkillsService {
  
  /// Key for tracking if defaults have been loaded
  private static let hasLoadedDefaultsKey = "peel.skills.hasLoadedDefaults"
  
  /// Key for tracking Ember skills per repo
  private static let emberSkillsLoadedPrefix = "peel.skills.ember.loaded."
  
  /// Key for storing skill bundle hash
  private static let emberSkillsHashKey = "peel.skills.ember.bundleHash"
  
  /// Skill definition from JSON
  struct SkillDefinition: Decodable {
    let title: String
    let body: String
    let tags: String
    let priority: Int
    let languages: [String]  // Empty array means applies to all repos
  }
  
  /// Ember skill definition from JSON bundle
  struct EmberSkillDefinition: Decodable {
    let title: String
    let body: String
    let tags: String
    let priority: Int
    let category: String
    let impact: String
  }
  
  /// Ember skills bundle metadata
  struct EmberSkillsBundle: Decodable {
    struct Meta: Decodable {
      let source: String
      let skill: String
      let version: String
      let lastUpdated: String
      let hash: String
      let url: String
    }
    let meta: Meta
    let skills: [EmberSkillDefinition]
  }
  
  /// Check if defaults have been loaded
  static var hasLoadedDefaults: Bool {
    get { UserDefaults.standard.bool(forKey: hasLoadedDefaultsKey) }
    set { UserDefaults.standard.set(newValue, forKey: hasLoadedDefaultsKey) }
  }
  
  /// Check if Ember skills have been loaded for a repo
  static func hasLoadedEmberSkills(repoPath: String) -> Bool {
    let key = emberSkillsLoadedPrefix + repoPath.replacingOccurrences(of: "/", with: "_")
    return UserDefaults.standard.bool(forKey: key)
  }
  
  /// Mark Ember skills as loaded for a repo
  static func setEmberSkillsLoaded(repoPath: String, loaded: Bool) {
    let key = emberSkillsLoadedPrefix + repoPath.replacingOccurrences(of: "/", with: "_")
    UserDefaults.standard.set(loaded, forKey: key)
  }
  
  /// Get stored hash of Ember skills bundle
  static var storedEmberSkillsHash: String? {
    get { UserDefaults.standard.string(forKey: emberSkillsHashKey) }
    set { UserDefaults.standard.set(newValue, forKey: emberSkillsHashKey) }
  }
  
  /// Load default skills from bundled JSON
  static func loadDefaultSkillDefinitions() -> [SkillDefinition] {
    guard let url = Bundle.main.url(forResource: "DefaultRepoSkills", withExtension: "json") else {
      print("[DefaultSkillsService] DefaultRepoSkills.json not found in bundle")
      return []
    }
    
    do {
      let data = try Data(contentsOf: url)
      let skills = try JSONDecoder().decode([SkillDefinition].self, from: data)
      return skills
    } catch {
      print("[DefaultSkillsService] Failed to load default skills: \(error)")
      return []
    }
  }
  
  /// Load Ember skills bundle
  static func loadEmberSkillsBundle() -> EmberSkillsBundle? {
    guard let url = Bundle.main.url(forResource: "EmberSkillsBundle", withExtension: "json") else {
      print("[DefaultSkillsService] EmberSkillsBundle.json not found in bundle")
      return nil
    }
    
    do {
      let data = try Data(contentsOf: url)
      let bundle = try JSONDecoder().decode(EmberSkillsBundle.self, from: data)
      return bundle
    } catch {
      print("[DefaultSkillsService] Failed to load Ember skills bundle: \(error)")
      return nil
    }
  }
  
  /// Compute hash of Ember skills bundle for update detection
  static func computeEmberSkillsHash() -> String? {
    guard let url = Bundle.main.url(forResource: "EmberSkillsBundle", withExtension: "json"),
          let data = try? Data(contentsOf: url) else {
      return nil
    }
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
  }
  
  // MARK: - Ember Project Detection
  
  /// Detect if a repo is an Ember project
  static func detectEmberProject(repoPath: String) -> Bool {
    let packagePath = URL(fileURLWithPath: repoPath).appendingPathComponent("package.json")
    
    guard let data = try? Data(contentsOf: packagePath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    
    let deps = (json["dependencies"] as? [String: Any] ?? [:]).keys
    let devDeps = (json["devDependencies"] as? [String: Any] ?? [:]).keys
    let allDeps = Set(deps).union(devDeps)
    
    // Check for Ember-specific dependencies
    let emberMarkers = [
      "ember-source",
      "ember-cli",
      "ember-data",
      "@ember/string",
      "@glimmer/component",
      "@glimmer/tracking"
    ]
    
    for marker in emberMarkers {
      if allDeps.contains(marker) {
        return true
      }
    }
    
    // Check for @ember/* dependencies
    for dep in allDeps {
      if dep.hasPrefix("@ember/") {
        return true
      }
    }
    
    return false
  }
  
  /// Seed Ember skills for a detected Ember project
  /// - Parameters:
  ///   - context: The SwiftData model context
  ///   - repoPath: Path to the Ember project
  ///   - force: Force re-seeding even if already done
  /// - Returns: Number of skills added
  @discardableResult
  static func seedEmberSkills(context: ModelContext, repoPath: String, force: Bool = false) -> Int {
    guard force || !hasLoadedEmberSkills(repoPath: repoPath) else {
      return 0
    }
    
    guard let bundle = loadEmberSkillsBundle() else {
      return 0
    }
    
    var addedCount = 0
    for skill in bundle.skills {
      let repoSkill = RepoGuidanceSkill(
        repoPath: repoPath,
        title: skill.title,
        body: skill.body,
        source: bundle.meta.source,
        tags: "\(skill.tags),\(skill.category),impact:\(skill.impact)",
        priority: skill.priority,
        isActive: true
      )
      context.insert(repoSkill)
      addedCount += 1
    }
    
    do {
      try context.save()
      setEmberSkillsLoaded(repoPath: repoPath, loaded: true)
      storedEmberSkillsHash = computeEmberSkillsHash()
      print("[DefaultSkillsService] Seeded \(addedCount) Ember skills for \(repoPath)")
    } catch {
      print("[DefaultSkillsService] Failed to save Ember skills: \(error)")
      return 0
    }
    
    return addedCount
  }
  
  /// Check if Ember project and auto-seed skills if needed
  /// - Parameters:
  ///   - context: The SwiftData model context
  ///   - repoPath: Path to check
  /// - Returns: Number of skills added (0 if not Ember or already seeded)
  @discardableResult
  static func autoSeedEmberSkillsIfNeeded(context: ModelContext, repoPath: String) -> Int {
    guard detectEmberProject(repoPath: repoPath) else {
      return 0
    }
    return seedEmberSkills(context: context, repoPath: repoPath)
  }
  
  /// Seed default skills into SwiftData if not already done
  /// - Parameters:
  ///   - context: The SwiftData model context
  ///   - force: Force re-seeding even if already done (useful for testing/updates)
  /// - Returns: Number of skills added
  @discardableResult
  static func seedDefaultSkills(context: ModelContext, force: Bool = false) -> Int {
    guard force || !hasLoadedDefaults else {
      return 0
    }
    
    let definitions = loadDefaultSkillDefinitions()
    guard !definitions.isEmpty else {
      return 0
    }
    
    var addedCount = 0
    for def in definitions {
      // Default skills use repoPath = "*" to indicate they apply to any repo
      // The UI can filter these based on the languages array if needed
      let skill = RepoGuidanceSkill(
        repoPath: "*",  // Universal skills
        title: def.title,
        body: def.body,
        source: "default",  // Mark as default so user knows they can override
        tags: def.tags + (def.languages.isEmpty ? "" : ",languages:\(def.languages.joined(separator: "|"))"),
        priority: def.priority,
        isActive: true
      )
      context.insert(skill)
      addedCount += 1
    }
    
    do {
      try context.save()
      hasLoadedDefaults = true
      print("[DefaultSkillsService] Seeded \(addedCount) default skills")
    } catch {
      print("[DefaultSkillsService] Failed to save default skills: \(error)")
      return 0
    }
    
    return addedCount
  }
  
  /// Get count of default skills (source = "default")
  static func countDefaultSkills(context: ModelContext) -> Int {
    let descriptor = FetchDescriptor<RepoGuidanceSkill>(
      predicate: #Predicate { $0.source == "default" }
    )
    return (try? context.fetchCount(descriptor)) ?? 0
  }
  
  /// Remove all default skills (for testing/reset)
  static func removeDefaultSkills(context: ModelContext) {
    let descriptor = FetchDescriptor<RepoGuidanceSkill>(
      predicate: #Predicate { $0.source == "default" }
    )
    
    do {
      let skills = try context.fetch(descriptor)
      for skill in skills {
        context.delete(skill)
      }
      try context.save()
      hasLoadedDefaults = false
      print("[DefaultSkillsService] Removed \(skills.count) default skills")
    } catch {
      print("[DefaultSkillsService] Failed to remove default skills: \(error)")
    }
  }
  
  /// Get count of Ember skills for a repo
  static func countEmberSkills(context: ModelContext, repoPath: String) -> Int {
    let source = "NullVoxPopuli/agent-skills"
    let descriptor = FetchDescriptor<RepoGuidanceSkill>(
      predicate: #Predicate { $0.repoPath == repoPath && $0.source == source }
    )
    return (try? context.fetchCount(descriptor)) ?? 0
  }
  
  /// Remove Ember skills for a repo (for testing/reset)
  static func removeEmberSkills(context: ModelContext, repoPath: String) {
    let source = "NullVoxPopuli/agent-skills"
    let descriptor = FetchDescriptor<RepoGuidanceSkill>(
      predicate: #Predicate { $0.repoPath == repoPath && $0.source == source }
    )
    
    do {
      let skills = try context.fetch(descriptor)
      for skill in skills {
        context.delete(skill)
      }
      try context.save()
      setEmberSkillsLoaded(repoPath: repoPath, loaded: false)
      print("[DefaultSkillsService] Removed \(skills.count) Ember skills for \(repoPath)")
    } catch {
      print("[DefaultSkillsService] Failed to remove Ember skills: \(error)")
    }
  }
  
  /// Update Ember skills for a repo (remove old, add new)
  @discardableResult
  static func updateEmberSkills(context: ModelContext, repoPath: String) -> Int {
    removeEmberSkills(context: context, repoPath: repoPath)
    return seedEmberSkills(context: context, repoPath: repoPath, force: true)
  }
}
