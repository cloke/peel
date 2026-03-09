//
//  RAGRepositoryCardSkillsSheet.swift
//  Peel
//

import OSLog
import PeelUI
import SwiftData
import SwiftUI

private let repoSkillsLogger = Logger(subsystem: "com.peel.rag", category: "skills")

// MARK: - Skills Sheet

struct RAGRepoSkillsSheet: View {
  let repo: MCPServerService.RAGRepoInfo
  @Bindable var mcpServer: MCPServerService
  @Environment(\.dismiss) private var dismiss
  
  @Query private var allSkills: [RepoGuidanceSkill]
  @State private var repoRemoteURL: String?
  @State private var repoTechTags: Set<String> = []
  private var repoSkills: [RepoGuidanceSkill] {
    allSkills.filter { repoSkillMatches($0) }
  }
  
  @State private var selectedSkillId: UUID?
  @State private var skillTitle: String = ""
  @State private var skillBody: String = ""
  @State private var skillTags: String = ""
  @State private var skillPriority: Int = 0
  @State private var skillActive: Bool = true
  @State private var skillSource: String = "manual"
  @State private var errorMessage: String?

  private func repoSkillMatches(_ skill: RepoGuidanceSkill) -> Bool {
    if skill.repoPath == "*" {
      let skillTags = RepoTechDetector.parseTags(skill.tags)
      if !repoTechTags.isEmpty {
        if !skillTags.isEmpty,
           !skillTags.isDisjoint(with: repoTechTags) {
          repoSkillsLogger.debug("Sheet skill matched by wildcard tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
          return true
        }
        repoSkillsLogger.debug("Sheet skill rejected by wildcard tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
        return false
      }
      repoSkillsLogger.debug("Sheet skill matched by wildcard path. skill=\(skill.title, privacy: .public)")
      return true
    }
    if skill.repoPath == repo.rootPath {
      repoSkillsLogger.debug("Sheet skill matched by repo path. skill=\(skill.title, privacy: .public) repo=\(repo.rootPath, privacy: .public)")
      return true
    }
    if let repoRemoteURL,
       !repoRemoteURL.isEmpty,
       !skill.repoRemoteURL.isEmpty,
       RepoRegistry.shared.normalizeRemoteURL(skill.repoRemoteURL) == RepoRegistry.shared.normalizeRemoteURL(repoRemoteURL) {
      repoSkillsLogger.debug("Sheet skill matched by repo remote. skill=\(skill.title, privacy: .public)")
      return true
    }
    if !skill.repoName.isEmpty {
      let repoName = URL(fileURLWithPath: repo.rootPath).lastPathComponent
      if repoName == skill.repoName {
        repoSkillsLogger.debug("Sheet skill matched by repo name. skill=\(skill.title, privacy: .public) repoName=\(repoName, privacy: .public)")
        return true
      }
    }
    let skillTags = RepoTechDetector.parseTags(skill.tags)
    if skill.repoPath.isEmpty || skill.repoPath == "*" {
      if !repoTechTags.isEmpty {
        if !skillTags.isEmpty,
           !skillTags.isDisjoint(with: repoTechTags) {
          repoSkillsLogger.debug("Sheet skill matched by tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
          return true
        }
        repoSkillsLogger.debug("Sheet skill rejected by tags. skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public) repoTags=\(String(describing: repoTechTags), privacy: .public)")
        return false
      }
      if !skillTags.isEmpty,
         !skillTags.isDisjoint(with: repoTechTags) {
        repoSkillsLogger.debug("Sheet skill matched by tags (no repo tags). skill=\(skill.title, privacy: .public) tags=\(skill.tags, privacy: .public)")
        return true
      }
    }
    return false
  }
  
  var body: some View {
    NavigationStack {
      HSplitView {
        // Skill list
        VStack(alignment: .leading) {
          List(selection: $selectedSkillId) {
            ForEach(repoSkills) { skill in
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(skill.title.isEmpty ? "Untitled" : skill.title)
                    .font(.callout)
                  
                  Spacer()
                  
                  if !skill.isActive {
                    Text("Inactive")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
                
                Text("Priority \(skill.priority) · Used \(skill.appliedCount)×")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .tag(skill.id)
            }
          }
          .listStyle(.sidebar)
          
          HStack {
            Button {
              createNewSkill()
            } label: {
              Label("New Skill", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            
            Spacer()
          }
          .padding(8)
        }
        .frame(minWidth: 200, maxWidth: 300)
        
        // Editor
        VStack(alignment: .leading, spacing: 12) {
          TextField("Title", text: $skillTitle)
            .textFieldStyle(.roundedBorder)
          
          HStack {
            TextField("Tags (comma-separated)", text: $skillTags)
              .textFieldStyle(.roundedBorder)
            
            Stepper("Priority: \(skillPriority)", value: $skillPriority, in: -5...10)
              .frame(width: 150)
          }
          
          Toggle("Active", isOn: $skillActive)
          
          Text("Guidance Content")
            .font(.caption)
            .foregroundStyle(.secondary)
          
          TextEditor(text: $skillBody)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3))
            )
          
          if let errorMessage {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }
          
          HStack {
            if selectedSkillId != nil {
              Button(role: .destructive) {
                deleteSkill()
              } label: {
                Label("Delete", systemImage: "trash")
              }
              .buttonStyle(.bordered)
            }
            
            Spacer()
            
            Button("Save") {
              saveSkill()
            }
            .buttonStyle(.borderedProminent)
            .disabled(skillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .padding()
        .frame(minWidth: 400)
      }
      .navigationTitle("Skills for \(repo.name)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .frame(minWidth: 700, minHeight: 500)
    .onChange(of: selectedSkillId) { _, newId in
      if let newId, let skill = repoSkills.first(where: { $0.id == newId }) {
        loadSkill(skill)
      }
    }
    .task {
      repoRemoteURL = await RepoRegistry.shared.registerRepo(at: repo.rootPath)
        ?? RepoRegistry.shared.getCachedRemoteURL(for: repo.rootPath)
      repoTechTags = RepoTechDetector.detectTags(repoPath: repo.rootPath)
    }
  }
  
  private func loadSkill(_ skill: RepoGuidanceSkill) {
    skillTitle = skill.title
    skillBody = skill.body
    skillTags = skill.tags
    skillPriority = skill.priority
    skillActive = skill.isActive
    skillSource = skill.source
    errorMessage = nil
  }
  
  private func createNewSkill() {
    selectedSkillId = nil
    skillTitle = ""
    skillBody = ""
    skillTags = ""
    skillPriority = 0
    skillActive = true
    skillSource = "manual"
    errorMessage = nil
  }
  
  private func saveSkill() {
    let trimmedBody = skillBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else {
      errorMessage = "Skill body is required"
      return
    }
    
    errorMessage = nil
    
    if let currentId = selectedSkillId,
       let updated = mcpServer.updateRepoGuidanceSkill(
         id: currentId,
         repoPath: repo.rootPath,
         repoRemoteURL: repoRemoteURL,
         repoName: repo.name,
         title: skillTitle,
         body: trimmedBody,
         source: skillSource,
         tags: skillTags,
         priority: skillPriority,
         isActive: skillActive
       ) {
      selectedSkillId = updated.id
    } else if let created = mcpServer.addRepoGuidanceSkill(
      repoPath: repo.rootPath,
      repoRemoteURL: repoRemoteURL,
      repoName: repo.name,
      title: skillTitle,
      body: trimmedBody,
      source: skillSource,
      tags: skillTags,
      priority: skillPriority,
      isActive: skillActive
    ) {
      selectedSkillId = created.id
    } else {
      errorMessage = "Failed to save skill"
    }
  }
  
  private func deleteSkill() {
    guard let selectedSkillId else { return }
    if mcpServer.deleteRepoGuidanceSkill(id: selectedSkillId) {
      createNewSkill()
    } else {
      errorMessage = "Failed to delete skill"
    }
  }
}
