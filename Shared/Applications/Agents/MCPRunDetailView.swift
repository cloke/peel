//
//  MCPRunDetailView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import Git
import SwiftData
import SwiftUI
import AppKit

struct MCPRunDetailView: View {
  let run: MCPRunRecord
  @Query private var results: [MCPRunResultRecord]
  @Query(sort: \MCPRunRecord.createdAt, order: .reverse) private var allRuns: [MCPRunRecord]
  @Environment(\.dismiss) private var dismiss
  @Environment(MCPServerService.self) private var mcpServer
  @State private var showingCompareSheet = false
  @State private var compareRun: MCPRunRecord?
  @State private var isLoadingWorktreeStatus = false
  @State private var worktreeChangedFiles: [String: Int] = [:]

  private var activeRunInfo: MCPServerService.ActiveRunInfo? {
    guard let chainId = UUID(uuidString: run.chainId) else { return nil }
    return mcpServer.activeRuns.first { $0.chainId == chainId }
  }

  private var activeChain: AgentChain? {
    mcpServer.agentManager.chains.first { $0.id.uuidString == run.chainId }
  }

  init(run: MCPRunRecord) {
    self.run = run
    let chainId = run.chainId
    _results = Query(
      filter: #Predicate { $0.chainId == chainId },
      sort: [SortDescriptor(\.createdAt, order: .forward)]
    )
  }

  private var plannerPrompt: String? {
    results.first { $0.agentName.lowercased().contains("planner") }?.prompt
  }

  private var worktreePaths: [String] {
    let raw = run.implementerWorkspacePaths
    let parsed = raw.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    if !parsed.isEmpty {
      return parsed
    }
    if let workingDirectory = run.workingDirectory, !workingDirectory.isEmpty {
      return [workingDirectory]
    }
    return []
  }

  private var implementerBranches: [String] {
    let raw = run.implementerBranches
    return raw.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
  }

  private var mergeConflictPaths: [String] {
    let raw = run.mergeConflicts
    return raw.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
  }

  private var mergeReadinessLabel: String {
    if run.mergeConflictsCount > 0 {
      return "Blocked"
    }
    return run.success ? "Ready" : "Pending"
  }

  private func refreshWorktreeStatus() async {
    guard !worktreePaths.isEmpty else { return }
    isLoadingWorktreeStatus = true
    defer { isLoadingWorktreeStatus = false }

    var status: [String: Int] = [:]
    for path in worktreePaths {
      let repository = Model.Repository(
        name: URL(fileURLWithPath: path).lastPathComponent,
        path: path
      )
      do {
        let output = try await Commands.simple(arguments: ["status", "--porcelain"], in: repository)
        let changedFiles = output.filter { !$0.isEmpty }.count
        status[path] = changedFiles
      } catch {
        status[path] = 0
      }
    }
    worktreeChangedFiles = status
  }

  private func exportRun() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "mcp-run-\(run.createdAt.formatted(date: .numeric, time: .omitted)).md"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      let content = markdownExport()
      try? content.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private func markdownExport() -> String {
    var lines: [String] = []
    lines.append("# MCP Run")
    lines.append("- Template: \(run.templateName)")
    lines.append("- Created: \(run.createdAt)")
    if let workingDirectory = run.workingDirectory, !workingDirectory.isEmpty {
      lines.append("- Working Directory: \(workingDirectory)")
    }
    if let error = run.errorMessage, !error.isEmpty {
      lines.append("- Error: \(error)")
    }
    if let noWorkReason = run.noWorkReason, !noWorkReason.isEmpty {
      lines.append("- Planner Decision: \(noWorkReason)")
    }
    lines.append("")
    lines.append("## Prompt")
    lines.append(run.prompt)
    lines.append("")
    lines.append("## Results")
    for result in results {
      lines.append("### \(result.agentName) (\(result.model))")
      lines.append("- Cost: \(result.premiumCost.premiumCostDisplay)")
      lines.append("- Timestamp: \(result.createdAt)")
      if let verdict = result.reviewVerdict, !verdict.isEmpty {
        lines.append("- Review Verdict: \(verdict)")
      }
      lines.append("")
      lines.append(result.output)
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  private func elapsedLabel(from start: Date, to end: Date) -> String {
    let elapsed = max(0, end.timeIntervalSince(start))
    let minutes = Int(elapsed) / 60
    let seconds = Int(elapsed) % 60
    if minutes > 0 {
      return "\(minutes)m \(seconds)s"
    }
    return "\(seconds)s"
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          GroupBox {
            VStack(alignment: .leading, spacing: 6) {
              Text(run.templateName)
                .font(.headline)
              Text(run.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
              if let workingDirectory = run.workingDirectory, !workingDirectory.isEmpty {
                Text(workingDirectory)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              if let error = run.errorMessage, !error.isEmpty {
                Text(error)
                  .font(.caption)
                  .foregroundStyle(.red)
              }
              if let noWorkReason = run.noWorkReason, !noWorkReason.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                  Image(systemName: "checkmark.seal")
                    .foregroundStyle(.green)
                  VStack(alignment: .leading, spacing: 4) {
                    Text("Planner Decision")
                      .font(.caption)
                      .fontWeight(.semibold)
                    Text(noWorkReason)
                      .font(.caption2)
                  }
                }
                .padding(8)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
              }
            }
          }

          if let activeRun = activeRunInfo {
            GroupBox("Active Run") {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(activeChain?.state.displayName ?? "Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Spacer()
                  Text(activeRun.startedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let chain = activeChain, chain.pauseOnReview, case .reviewing = chain.state {
                  Text("Paused for review gate")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("agents.mcpRunDetail.activeRun.reviewGatePaused")
                }
                HStack(spacing: 8) {
                  Button("Pause") {
                    Task { await mcpServer.pauseRun(activeRun.id) }
                  }
                  .buttonStyle(.bordered)
                  .accessibilityIdentifier("agents.mcpRunDetail.activeRun.\(run.id.uuidString).pause")

                  Button("Resume") {
                    Task { await mcpServer.resumeRun(activeRun.id) }
                  }
                  .buttonStyle(.bordered)
                  .accessibilityIdentifier("agents.mcpRunDetail.activeRun.\(run.id.uuidString).resume")

                  Button("Step") {
                    Task { await mcpServer.stepRun(activeRun.id) }
                  }
                  .buttonStyle(.bordered)
                  .accessibilityIdentifier("agents.mcpRunDetail.activeRun.\(run.id.uuidString).step")

                  Button("Stop") {
                    Task { await mcpServer.stopRun(activeRun.id) }
                  }
                  .buttonStyle(.bordered)
                  .tint(.red)
                  .accessibilityIdentifier("agents.mcpRunDetail.activeRun.\(run.id.uuidString).stop")
                }
              }
            }
          }

          if !worktreePaths.isEmpty {
            GroupBox("Worktrees") {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(worktreePaths, id: \.self) { path in
                  HStack {
                    Text(path)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                    if let changed = worktreeChangedFiles[path], changed > 0 {
                      Chip(
                        text: "\(changed) changed",
                        font: .caption2,
                        foreground: .orange,
                        background: Color.orange.opacity(0.15),
                        horizontalPadding: 6,
                        verticalPadding: 2
                      )
                    }
                    Spacer()
                    Button("VS Code") {
                      Task { try? await VSCodeService.shared.open(path: path, newWindow: true) }
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("agents.mcpRunDetail.worktree.openVSCode")
                    Button("Open") {
                      NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("agents.mcpRunDetail.worktree.openFinder")
                  }
                }
                if isLoadingWorktreeStatus {
                  Text("Checking worktree status...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Button("Clean Worktrees") {
                  Task { await mcpServer.cleanupWorktrees(paths: worktreePaths) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("agents.mcpRunDetail.worktree.clean")
              }
            }
          }

          GroupBox("Merge Readiness") {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("Status")
                  .font(.caption)
                Spacer()
                Text(mergeReadinessLabel)
                  .font(.caption)
                  .foregroundStyle(run.mergeConflictsCount > 0 ? .red : .green)
                  .accessibilityIdentifier("agents.mcpRunDetail.mergeReadiness.status")
              }
              if run.mergeConflictsCount > 0 {
                Text("Conflicts detected: \(run.mergeConflictsCount)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier("agents.mcpRunDetail.mergeReadiness.conflicts")
              }
              if !implementerBranches.isEmpty {
                Text("Implementer branches: \(implementerBranches.joined(separator: ", "))")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier("agents.mcpRunDetail.mergeReadiness.branches")
              }
            }
          }

          if !mergeConflictPaths.isEmpty {
            GroupBox("Merge Conflicts") {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(mergeConflictPaths, id: \.self) { path in
                  HStack {
                    Text(path)
                      .font(.caption.monospaced())
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                    Spacer()
                    Button("VS Code") {
                      Task { try? await VSCodeService.shared.openFile(path) }
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("agents.mcpRunDetail.mergeConflicts.openVSCode")
                    Button("Open") {
                      NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("agents.mcpRunDetail.mergeConflicts.openFinder")
                  }
                }
              }
            }
          }

          // Screenshots
          let screenshotPaths = run.screenshotPaths.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
          if !screenshotPaths.isEmpty {
            GroupBox("Screenshots") {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(screenshotPaths, id: \.self) { path in
                    if let url = URL(fileURLWithPath: path) as URL? {
                      AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                          image.resizable().scaledToFill().frame(width: 120, height: 80).clipped().cornerRadius(6)
                        default:
                          Rectangle().fill(Color.secondary).frame(width: 120, height: 80).cornerRadius(6)
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          GroupBox("User Prompt") {
            Text(run.prompt)
              .font(.caption)
              .textSelection(.enabled)
          }

          if let plannerPrompt {
            GroupBox("Planner Prompt") {
              Text(plannerPrompt)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
          }

          GroupBox("Timeline") {
            if results.isEmpty {
              Text("No timeline entries yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                  HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                      Circle()
                        .fill(Color.blue.opacity(0.6))
                        .frame(width: 8, height: 8)
                      if index < results.count - 1 {
                        Rectangle()
                          .fill(Color.secondary.opacity(0.3))
                          .frame(width: 2)
                          .frame(maxHeight: 24)
                      }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                      HStack(spacing: 8) {
                        Text(result.agentName)
                          .font(.subheadline)
                          .fontWeight(.medium)
                        Text(result.model)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                        Spacer()
                        Text(elapsedLabel(from: run.createdAt, to: result.createdAt))
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                      Text(result.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                  }
                }
              }
              .padding(.vertical, 4)
            }
          }

          GroupBox("Agent Outputs") {
            if results.isEmpty {
              Text("No outputs recorded for this run.")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(results) { result in
                  VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                      Text(result.agentName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                      Text(result.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                      Text(result.premiumCost.premiumMultiplierString())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                      Text(result.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                      Spacer()
                      if let verdict = result.reviewVerdict, !verdict.isEmpty {
                        Chip(
                          text: verdict,
                          background: Color.secondary.opacity(0.15)
                        )
                      }
                    }
                    Text(result.output)
                      .font(.caption)
                      .textSelection(.enabled)
                  }
                  if result.id != results.last?.id {
                    Divider()
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, 4)
      }
      .navigationTitle("MCP Run")
      .task {
        await refreshWorktreeStatus()
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
          .accessibilityIdentifier("agents.mcpRunDetail.done")
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Export") {
            exportRun()
          }
          .accessibilityIdentifier("agents.mcpRunDetail.export")
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Compare") {
            compareRun = allRuns.first(where: { $0.id != run.id })
            showingCompareSheet = true
          }
          .disabled(allRuns.filter { $0.id != run.id }.isEmpty)
          .accessibilityIdentifier("agents.mcpRunDetail.compare")
        }
      }
    }
    .sheet(isPresented: $showingCompareSheet) {
      if let compareRun {
        CompareRunSheet(currentRun: run, runs: allRuns, compareRun: compareRun)
      }
    }
  }
}

struct CompareRunSheet: View {
  let currentRun: MCPRunRecord
  let runs: [MCPRunRecord]
  @State private var compareRunId: String
  @Query private var currentResults: [MCPRunResultRecord]
  @Query private var compareResults: [MCPRunResultRecord]
  @Environment(\.dismiss) private var dismiss

  init(currentRun: MCPRunRecord, runs: [MCPRunRecord], compareRun: MCPRunRecord) {
    self.currentRun = currentRun
    self.runs = runs
    _compareRunId = State(initialValue: compareRun.chainId)
    let currentChainId = currentRun.chainId
    _currentResults = Query(
      filter: #Predicate { $0.chainId == currentChainId },
      sort: [SortDescriptor(\.createdAt, order: .forward)]
    )
    _compareResults = Query(
      filter: #Predicate { $0.chainId == compareRunId },
      sort: [SortDescriptor(\.createdAt, order: .forward)]
    )
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Compare with", selection: $compareRunId) {
          ForEach(runs.filter { $0.id != currentRun.id }) { run in
            Text(run.templateName + " • " + run.createdAt.formatted(date: .abbreviated, time: .shortened))
              .tag(run.chainId)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("agents.mcpRunCompare.picker")

        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Current Run")
              .font(.headline)
            ForEach(currentResults) { result in
              VStack(alignment: .leading, spacing: 4) {
                Text(result.agentName)
                  .font(.subheadline)
                  .fontWeight(.medium)
                Text(result.output)
                  .font(.caption)
                  .textSelection(.enabled)
              }
              .padding(.vertical, 4)
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            Text("Compare Run")
              .font(.headline)
            ForEach(compareResults) { result in
              VStack(alignment: .leading, spacing: 4) {
                Text(result.agentName)
                  .font(.subheadline)
                  .fontWeight(.medium)
                Text(result.output)
                  .font(.caption)
                  .textSelection(.enabled)
              }
              .padding(.vertical, 4)
            }
          }
        }
        Spacer()
      }
      .padding()
      .navigationTitle("Compare Runs")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("agents.mcpRunCompare.done")
        }
      }
    }
  }
}
