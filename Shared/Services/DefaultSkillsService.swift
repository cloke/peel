//
//  DefaultSkillsService.swift
//  Peel
//
//  Loads default repo guidance skills on first launch.
//  Issue #90
//

import Foundation
import SwiftData

/// Service for seeding default repo guidance skills
enum DefaultSkillsService {
  
  /// Key for tracking if defaults have been loaded
  private static let hasLoadedDefaultsKey = "peel.skills.hasLoadedDefaults"
  
  /// Skill definition from JSON
  struct SkillDefinition: Decodable {
    let title: String
    let body: String
    let tags: String
    let priority: Int
    let languages: [String]  // Empty array means applies to all repos
  }
  
  /// Check if defaults have been loaded
  static var hasLoadedDefaults: Bool {
    get { UserDefaults.standard.bool(forKey: hasLoadedDefaultsKey) }
    set { UserDefaults.standard.set(newValue, forKey: hasLoadedDefaultsKey) }
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
}
