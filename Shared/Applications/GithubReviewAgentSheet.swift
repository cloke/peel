//
//  GithubReviewAgentSheet.swift
//  Peel
//
//  Created on 1/20/26.
//

import SwiftUI
import Github
import PeelUI

struct PRReviewAgentTarget: Identifiable {
  let id: UUID
  let recentPR: RecentPRInfo?
  let pullRequest: Github.PullRequest?
  let repository: Github.Repository?

  static func from(pullRequest: Github.PullRequest, repository: Github.Repository) -> PRReviewAgentTarget {
    PRReviewAgentTarget(id: UUID(), recentPR: nil, pullRequest: pullRequest, repository: repository)
  }

  static func from(recentPR: RecentPRInfo) -> PRReviewAgentTarget {
    PRReviewAgentTarget(id: UUID(), recentPR: recentPR, pullRequest: nil, repository: nil)
  }
}

struct GithubReviewAgentSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(MCPServerService.self) private var mcpServer

  let target: PRReviewAgentTarget

  @State private var service = ReviewLocallyService.shared
  @State private var isLoadingPR = false
  @State private var errorMessage: String?
  @State private var pullRequest: Github.PullRequest?
  @State private var repository: Github.Repository?
  @State private var selectedRepoPath: String = ""
  @State private var openInVSCode = false
  @State private var selectedTemplateId: UUID?
  @State private var prompt: String = ""
  @State private var isRunning = false
  @State private var lastSummary: AgentChainRunner.RunSummary?

  var body: some View {
    VStack(spacing: 0) {
      headerView
      Divider()
      contentView
      Divider()
      footerView
    }
    .frame(width: 520, height: 520)
    .onAppear {
      if selectedRepoPath.isEmpty, let lastPath = service.lastSelectedRepoPath {
        selectedRepoPath = lastPath
      }
      Task { await loadPRIfNeeded() }
      autoSelectRepository()
    }
  }

  private var headerView: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "sparkles")
          .font(.title)
          .foregroundStyle(.purple)

        VStack(alignment: .leading, spacing: 2) {
          Text("Review with Agent")
            .font(.headline)
          Text(headerSubtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
      }
    }
    .padding()
  }

  private var headerSubtitle: String {
    if let pr = pullRequest {
      return "PR #\(pr.number): \(pr.title ?? "Untitled")"
    }
    if let recent = target.recentPR {
      return "PR #\(recent.prNumber): \(recent.title)"
    }
    return "Loading PR"
  }

  @ViewBuilder
  private var contentView: some View {
    if isLoadingPR {
      ProgressView("Loading PR...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let errorMessage {
      ErrorView(message: errorMessage) {
        Task { await loadPRIfNeeded() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Text("Local Repository")
                .font(.headline)

              TextField("Path to local repository", text: $selectedRepoPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("github.reviewAgent.repoPath")

              HStack(spacing: 8) {
                Button("Browse…") {
                  if let path = service.browseForRepository() {
                    selectedRepoPath = path
                    service.lastSelectedRepoPath = path
                  }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("github.reviewAgent.repoBrowse")

                Toggle("Open in VS Code", isOn: $openInVSCode)
                  .accessibilityIdentifier("github.reviewAgent.openInVSCode")
              }

              if !service.recentRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  Text("Recent Repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                  ForEach(service.recentRepositories.prefix(6)) { repo in
                    Button {
                      selectedRepoPath = repo.path
                    } label: {
                      HStack {
                        Image(systemName: "folder")
                          .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                          Text(repo.name)
                            .font(.callout)
                          Text(repo.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        if let repository, service.repositoryMatches(local: repo, githubRepo: repository) {
                          Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        }
                      }
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
            }
          }

          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Text("Agent Template")
                .font(.headline)

              Picker("Template", selection: selectedTemplateBinding) {
                ForEach(mcpServer.agentManager.allTemplates, id: \.id) { template in
                  Text(template.name).tag(template.id)
                }
              }
              .pickerStyle(.menu)
              .accessibilityIdentifier("github.reviewAgent.template")
            }
          }

          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Text("Prompt")
                .font(.headline)
              TextEditor(text: $prompt)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                .accessibilityIdentifier("github.reviewAgent.prompt")
            }
          }

          if let summary = lastSummary {
            GroupBox {
              VStack(alignment: .leading, spacing: 6) {
                Text(summary.errorMessage == nil ? "Review Complete" : "Review Failed")
                  .font(.headline)
                  .foregroundStyle(summary.errorMessage == nil ? .green : .red)
                Text("Agents: \(summary.results.count) · Conflicts: \(summary.mergeConflicts.count)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let error = summary.errorMessage {
                  Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
              }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    }
  }

  private var footerView: some View {
    HStack {
      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("github.reviewAgent.cancel")

      Spacer()

      Button(isRunning ? "Running…" : "Run Review") {
        Task { await runReview() }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isRunning || selectedRepoPath.isEmpty || pullRequest == nil || repository == nil)
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("github.reviewAgent.run")
    }
    .padding()
  }

  private var selectedTemplateBinding: Binding<UUID> {
    Binding(
      get: {
        if let selectedTemplateId {
          return selectedTemplateId
        }
        let defaultTemplate = mcpServer.agentManager.allTemplates.first { $0.name == "Code Review" }
          ?? mcpServer.agentManager.allTemplates.first
        let value = defaultTemplate?.id ?? UUID()
        selectedTemplateId = value
        return value
      },
      set: { selectedTemplateId = $0 }
    )
  }

  private func loadPRIfNeeded() async {
    if let pr = target.pullRequest, let repo = target.repository {
      pullRequest = pr
      repository = repo
      prompt = defaultPrompt(pullRequest: pr, repository: repo)
      autoSelectRepository()
      return
    }

    guard let recent = target.recentPR else { return }
    isLoadingPR = true
    defer { isLoadingPR = false }

    let parts = recent.repoFullName.split(separator: "/")
    guard parts.count == 2 else {
      errorMessage = "Invalid repository name"
      return
    }

    let ownerLogin = String(parts[0])
    let repoName = String(parts[1])

    do {
      async let repoTask = Github.repository(owner: ownerLogin, name: repoName)
      async let prTask = Github.pullRequest(owner: ownerLogin, repository: repoName, number: recent.prNumber)
      let (repo, pr) = try await (repoTask, prTask)
      repository = repo
      pullRequest = pr
      prompt = defaultPrompt(pullRequest: pr, repository: repo)
      autoSelectRepository()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func defaultPrompt(pullRequest: Github.PullRequest, repository: Github.Repository) -> String {
    let title = pullRequest.title ?? "Untitled"
    let body = (pullRequest.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return """
Review PR #\(pullRequest.number) in \(repository.full_name ?? repository.name).
Title: \(title)
Branch: \(pullRequest.head.ref)

Description:
\(body.isEmpty ? "(No description)" : body)

Task:
- Review code changes for correctness, bugs, edge cases, and style.
- Summarize risks and provide actionable suggestions.
- If tests are appropriate, run the relevant test suite.
"""
  }

  private func autoSelectRepository() {
    guard selectedRepoPath.isEmpty, let repository else { return }
    if let match = service.recentRepositories.first(where: { service.repositoryMatches(local: $0, githubRepo: repository) }) {
      selectedRepoPath = match.path
    }
  }

  private func runReview() async {
    guard let pullRequest else { return }
    errorMessage = nil
    isRunning = true
    lastSummary = nil
    defer { isRunning = false }

    await service.reviewLocally(
      pullRequest: pullRequest,
      localRepoPath: selectedRepoPath,
      openInVSCode: openInVSCode
    )

    guard case .complete(let worktreePath) = service.state else {
      if case .error(let message) = service.state {
        errorMessage = message
      }
      return
    }

    let template = mcpServer.agentManager.allTemplates.first { $0.id == selectedTemplateId }
      ?? mcpServer.agentManager.allTemplates.first
    guard let template else {
      errorMessage = "No chain templates available."
      return
    }

    let chain = mcpServer.agentManager.createChainFromTemplate(template, workingDirectory: worktreePath)
    mcpServer.agentManager.selectedChain = chain

    let runner = AgentChainRunner(
      agentManager: mcpServer.agentManager,
      cliService: mcpServer.cliService,
      telemetryProvider: MCPTelemetryAdapter(sessionTracker: mcpServer.sessionTracker)
    )
    let summary = await runner.runChain(chain, prompt: prompt)
    lastSummary = summary
  }
}
