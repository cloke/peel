//
//  ChainDetailView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import MCPCore
import PeelUI
import SwiftUI
import AppKit

struct ChainDetailView: View {
  let chain: AgentChain
  @Bindable var agentManager: AgentManager
  @Bindable var cliService: CLIService
  @Bindable var sessionTracker: SessionTracker

  @State private var prompt = ""
  @State private var isRunning = false
  @State private var errorMessage: String?
  @State private var mergeConflicts: [String] = []
  @State private var showingSaveTemplate = false
  @State private var showPremiumWarning = false

  private var plannerDecision: PlannerDecision? {
    chain.results.first(where: { $0.plannerDecision != nil })?.plannerDecision
  }

  /// Calculate total duration from run start time
  private var totalDuration: String? {
    guard let startTime = chain.runStartTime,
          case .complete = chain.state else { return nil }
    let elapsed = Date().timeIntervalSince(startTime)
    let minutes = Int(elapsed) / 60
    let seconds = Int(elapsed) % 60
    if minutes > 0 {
      return "\(minutes)m \(seconds)s"
    } else {
      return "\(seconds)s"
    }
  }

  /// Calculate elapsed time for running chains
  private var elapsedTime: String? {
    guard let startTime = chain.runStartTime else { return nil }
    let elapsed = Date().timeIntervalSince(startTime)
    let minutes = Int(elapsed) / 60
    let seconds = Int(elapsed) % 60
    if minutes > 0 {
      return "\(minutes)m \(seconds)s"
    } else {
      return "\(seconds)s"
    }
  }

  /// Get the currently active agent (if any)
  private var activeAgent: (index: Int, agent: Agent)? {
    for (index, agent) in chain.agents.enumerated() {
      if agent.state.isActive {
        return (index, agent)
      }
    }
    return nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        // Header
        HStack(spacing: 16) {
          ZStack {
            Circle()
              .fill(Color.purple.opacity(0.2))
              .frame(width: 60, height: 60)
            Image(systemName: "link")
              .font(.title)
              .foregroundStyle(.purple)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(chain.name).font(.title2).fontWeight(.semibold)
            HStack {
              Text("\(chain.agents.count) agents")
              Text("•")
              Text(chain.state.displayName)
            }.font(.subheadline).foregroundStyle(.secondary)
          }
          Spacer()
        }

        // Working directory - REQUIRED
        SectionCard("Project Folder") {
          HStack {
            Image(systemName: "folder.fill")
              .foregroundStyle(chain.workingDirectory == nil ? .orange : .green)
            Spacer()
            if let dir = chain.workingDirectory {
              Text(URL(fileURLWithPath: dir).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
              Button {
                chain.workingDirectory = nil
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("agents.chainDetail.project.clear")
            }
            Button("Select...") {
              selectFolder()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.chainDetail.project.select")
          }

          if chain.workingDirectory == nil {
            Label("Select a project folder to run the chain", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Divider()

        // Agents in chain
        VStack(alignment: .leading, spacing: 12) {
          Label("Agents in Chain", systemImage: "list.number").font(.headline)

          if chain.plannerOverridesAllowed {
            let message = chain.plannerOverridesApplied
              ? "Planner overrides applied (agents updated)"
              : "Planner overrides pending (showing template agents)"
            Label(message, systemImage: "wand.and.stars")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          // Group agents by role: planner, implementers, reviewer
          let agentsWithIndex = Array(chain.agents.enumerated())
          let planner = agentsWithIndex.first { $0.element.role == .planner }
          let reviewer = agentsWithIndex.last { $0.element.role == .reviewer }
          let implementers = agentsWithIndex.filter { $0.element.role == .implementer }

          // Planner (if exists)
          if let (index, agent) = planner {
            agentCard(index: index, agent: agent, chain: chain)
          }

          // Implementers Grid (if any)
          if !implementers.isEmpty {
            let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
              ForEach(implementers, id: \.element.id) { index, agent in
                agentCard(index: index, agent: agent, chain: chain)
              }
            }
          }

          // Reviewer (if exists and not same as planner)
          if let (index, agent) = reviewer, reviewer?.element.id != planner?.element.id {
            agentCard(index: index, agent: agent, chain: chain)
          }
        }

        Divider()

        if chain.runSource == .mcp {
          // MCP chain - show prompt and live status
          VStack(alignment: .leading, spacing: 16) {
            // Task prompt section
            if let initialPrompt = chain.initialPrompt {
              SectionCard {
                ScrollView {
                  Text(initialPrompt)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
              } header: {
                HStack(spacing: 8) {
                  Image(systemName: "text.alignleft")
                    .foregroundStyle(.purple)
                  Text("Task Prompt")
                }
              }
            }

            // Live status section (when running)
            if case .running = chain.state {
              SectionCard {
                VStack(alignment: .leading, spacing: 12) {
                  // Current agent / phase
                  HStack {
                    if let (index, agent) = activeAgent {
                      VStack(alignment: .leading, spacing: 4) {
                        HStack {
                          Text("Step \(index + 1) of \(chain.agents.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                          Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                          Text(chain.state.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Text(agent.name)
                          .font(.body)
                          .fontWeight(.medium)
                        Text("\(agent.role.displayName) • \(agent.model.displayName)")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                      Spacer()
                      Chip(
                        text: agent.state.displayName,
                        foreground: .white,
                        background: agent.state.color,
                        verticalPadding: 3
                      )
                    } else {
                      Text(chain.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                      Spacer()
                    }
                  }

                  // Elapsed time (live, updates every second)
                  if let startTime = chain.runStartTime {
                    HStack {
                      Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                      ElapsedTimeView(startTime: startTime)
                    }
                  }

                  // Partial usage while running (if results already available)
                  if !chain.results.isEmpty {
                    HStack(spacing: 6) {
                      Image(systemName: "creditcard")
                        .foregroundStyle(.secondary)
                      Text("Partial usage: \(chain.results.reduce(0.0) { $0 + $1.premiumCost }.premiumCostDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                }
              } header: {
                HStack(spacing: 8) {
                  Image(systemName: "play.circle.fill")
                    .foregroundStyle(.blue)
                  Text(chain.state.displayName)
                }
              }
            }

            // Live status panel (scrollable log + progress bars)
            if case .running = chain.state {
              LiveStatusPanel(chain: chain)
            }

            // MCP managed badge (small, not dominant)
            HStack {
              Chip(
                text: "MCP Managed",
                foreground: .purple,
                background: Color.purple.opacity(0.1),
                verticalPadding: 3
              )
              Spacer()
            }
          }
        } else {
          // Prompt input
          VStack(alignment: .leading, spacing: 8) {
            Label("Task Prompt", systemImage: "text.alignleft").font(.headline)
            TextEditor(text: $prompt)
              .font(.system(.body, design: .monospaced))
              .frame(minHeight: 100)
              .padding(8)
              .background(Color.secondary.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .accessibilityIdentifier("agents.chainDetail.prompt")

            Text("This prompt will be sent to Agent 1. Agent 2 will receive Agent 1's output as context.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          // Review loop settings (only show if there's a reviewer in the chain)
          if chain.agents.contains(where: { $0.role == .reviewer }) {
            SectionCard("Review Loop") {
              Toggle(isOn: Binding(
                get: { chain.enableReviewLoop },
                set: { chain.enableReviewLoop = $0 }
              )) {
                Label("Enable Review Loop", systemImage: "arrow.triangle.2.circlepath")
              }
              .accessibilityIdentifier("agents.chainDetail.reviewLoop.enabled")

              if chain.enableReviewLoop {
                Toggle(isOn: Binding(
                  get: { chain.pauseOnReview },
                  set: { chain.pauseOnReview = $0 }
                )) {
                  Label("Pause on Review Request", systemImage: "pause.circle")
                }
                .accessibilityIdentifier("agents.chainDetail.reviewLoop.pauseOnReview")

                HStack {
                  Text("Max iterations:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Picker("", selection: Binding(
                    get: { chain.maxReviewIterations },
                    set: { chain.maxReviewIterations = $0 }
                  )) {
                    ForEach([1, 2, 3, 5], id: \.self) { num in
                      Text("\(num)").tag(num)
                    }
                  }
                  .pickerStyle(.segmented)
                  .frame(width: 150)
                  .accessibilityIdentifier("agents.chainDetail.reviewLoop.maxIterations")
                }

                Text("If reviewer requests changes, re-run implementer with feedback")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }

          // Estimated cost display
          if !isRunning {
            HStack(spacing: 8) {
              Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
              Text("Estimated:")
                .foregroundStyle(.secondary)
              HStack(spacing: 4) {
                Image(systemName: "creditcard")
                  .foregroundStyle(.secondary)
                Text(estimatedCostDisplay)
                  .fontWeight(.medium)
              }
              estimatedCostTierBadge
            }
            .font(.caption)
          }

          // Run button
          HStack {
            Button {
              // Save working directory for next time
              if let dir = chain.workingDirectory {
                agentManager.lastUsedWorkingDirectory = dir
              }

              // Check if we should show premium warning
              if agentManager.shouldShowPremiumWarning(for: chain) {
                showPremiumWarning = true
              } else {
                Task { await runChain() }
              }
            } label: {
              Label(isRunning ? "Running..." : "Run Chain", systemImage: isRunning ? "hourglass" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || prompt.isEmpty || chain.workingDirectory == nil)
            .accessibilityIdentifier("agents.chainDetail.run")

            if isRunning {
              ProgressView().scaleEffect(0.8)
            }

            Spacer()

            if !chain.results.isEmpty {
              Text("Total: \(chain.results.reduce(0) { $0 + $1.premiumCost }.premiumCostDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        // Live status panel when running
        if isRunning {
          LiveStatusPanel(chain: chain)
        }

        // Completion banner (show when just completed)
        if case .complete = chain.state, !chain.results.isEmpty {
          SectionCard {
            HStack {
              Text("\(chain.results.count) agents")
              Text("•")
              Text(chain.results.reduce(0.0) { $0 + $1.premiumCost }.premiumCostDisplay)
              if let duration = totalDuration {
                Text("•")
                Text(duration)
              }
              Spacer()
              Button {
                // Clear results to run again
                prompt = ""
              } label: {
                Label("New Task", systemImage: "plus")
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.chainDetail.newTask")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          } header: {
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("Chain Completed")
              Spacer()
              StatusPill(text: "Success", style: .success)
            }
          }
        }

        // Error
        if let error = errorMessage {
          SectionCard {
            Text(error)
              .font(.caption)
          } header: {
            HStack {
              Label("Error", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
              Spacer()
              StatusPill(text: "Failed", style: .error)
            }
          }
        }

        if !mergeConflicts.isEmpty {
          SectionCard {
            Text("Resolve these files, then re-run the reviewer.")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(Array(mergeConflicts.enumerated()), id: \.offset) { index, path in
              HStack(spacing: 8) {
                Text(path)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                Spacer()
                Button("VS Code") {
                  Task { try? await VSCodeService.shared.openFile(path) }
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("agents.chainDetail.mergeConflicts.\(index).openVSCode")
                Button("Reveal") {
                  NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("agents.chainDetail.mergeConflicts.\(index).reveal")
              }
            }

            if let path = chain.workingDirectory {
              Button("Open Repo in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.chainDetail.mergeConflicts.openFinder")
            }
          } header: {
            HStack {
              Label("Merge Conflicts", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              Spacer()
              StatusPill(text: "\(mergeConflicts.count) files", style: .warning)
            }
          }
        }

        // Results
        if !chain.results.isEmpty {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Label("Results", systemImage: "doc.text").font(.headline)
              Spacer()
              if case .complete = chain.state {
                Chip(
                  text: "Completed",
                  font: .caption,
                  foreground: .green,
                  background: Color.green.opacity(0.15),
                  horizontalPadding: 8
                )
              }
            }

            ForEach(chain.results) { result in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(result.agentName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                  Text("(\(result.model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                  // Show review verdict if present
                  if let verdict = result.reviewVerdict {
                    Spacer()
                    Chip(
                      text: verdict.displayName,
                      systemImage: verdict.iconName,
                      font: .caption,
                      foreground: verdict.swiftUIColor,
                      background: verdict.swiftUIColor.opacity(0.15),
                      horizontalPadding: 8,
                      verticalPadding: 4
                    )
                  }

                  Spacer()
                  if let duration = result.duration {
                    Text(duration)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }

                ScrollView {
                  Text(result.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
              }
            }
          }

          // Save as template option (after successful run)
          if case .complete = chain.state {
            Divider()

            HStack {
              VStack(alignment: .leading) {
                Text("Save Configuration")
                  .font(.subheadline)
                  .fontWeight(.medium)
                Text("Save this chain as a reusable template")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer()

              Button {
                showingSaveTemplate = true
              } label: {
                Label("Save as Template", systemImage: "square.and.arrow.down")
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.chainDetail.saveTemplate")
            }
          }
        }

        Spacer()
      }
      .padding()
    }
    .navigationTitle(chain.name)
    .sheet(isPresented: $showingSaveTemplate) {
      SaveTemplateSheet(chain: chain, agentManager: agentManager)
    }
    .confirmationDialog(
      "Premium Model Usage",
      isPresented: $showPremiumWarning,
      titleVisibility: .visible
    ) {
      Button("Run Chain") {
        Task { await runChain() }
      }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("This chain uses \(estimatedCostTier.displayName.lowercased()) models with an estimated cost of \(estimatedCostDisplay). Premium requests count toward your monthly quota.")
    }
    .onAppear {
      // Load last working directory if chain doesn't have one
      if chain.workingDirectory == nil {
        chain.workingDirectory = agentManager.lastUsedWorkingDirectory
      }
    }
  }

  // MARK: - Agent Card View

  @ViewBuilder
  private func agentCard(index: Int, agent: Agent, chain: AgentChain) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        // Role icon with consistent sizing
        Image(systemName: agent.role.iconName)
          .frame(width: 20, height: 20)
          .foregroundStyle(.secondary)

        // Agent number with status indicator
        ZStack {
          Circle()
            .fill(agentStatusColor(for: index, agent: agent))
            .frame(width: 24, height: 24)

          if chain.results.contains(where: { $0.agentId == agent.id }) {
            Image(systemName: "checkmark")
              .font(.caption2.bold())
              .foregroundStyle(.white)
          } else if isAgentRunning(at: index) {
            ProgressView()
              .progressViewStyle(.circular)
              .scaleEffect(0.4)
              .tint(.white)
          } else {
            Text("\(index + 1)")
              .font(.caption2.bold())
              .foregroundStyle(agentNumberColor(for: index, agent: agent))
          }
        }

        Spacer()

        // Status pill (compact)
        if isAgentRunning(at: index) {
          Chip(
            text: "Running",
            foreground: .white,
            background: Color.blue,
            verticalPadding: 3
          )
        } else if agent.state == .complete || chain.results.contains(where: { $0.agentId == agent.id }) {
          Chip(
            text: "Complete",
            foreground: .green,
            background: Color.green.opacity(0.15),
            verticalPadding: 3
          )
        } else if case .running = chain.state, agent.state == .idle {
          Chip(
            text: "Queued",
            foreground: .secondary,
            background: Color.secondary.opacity(0.15),
            verticalPadding: 3
          )
        } else if case .failed = agent.state {
          Chip(
            text: "Failed",
            foreground: .red,
            background: Color.red.opacity(0.15),
            verticalPadding: 3
          )
        }
      }

      // Role badge
      Chip(
        text: agent.role.displayName,
        fontWeight: .semibold,
        background: Color.secondary.opacity(0.1)
      )

      // Agent name
      Text(agent.name)
        .font(.subheadline)
        .fontWeight(isAgentRunning(at: index) ? .semibold : .medium)
        .lineLimit(2)

      // Model and cost info
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if let result = chain.results.first(where: { $0.agentId == agent.id }) {
            Text("Actual: \(result.model)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("•")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\(result.premiumCost.premiumMultiplierString()) used")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text(agent.model.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if agent.state.isActive {
            Text("•")
              .font(.caption)
              .foregroundStyle(.secondary)
            Label(agent.state.displayName, systemImage: agent.state.iconName)
              .font(.caption)
              .foregroundStyle(agent.state.color)
          }
        }

        if agent.role == .implementer,
           let decision = plannerDecision {
          let implementers = chain.agents.filter { $0.role == .implementer }
          if let implIndex = implementers.firstIndex(where: { $0.id == agent.id }),
             implIndex < decision.tasks.count,
             let recommended = decision.tasks[implIndex].recommendedModel {
            if recommended != agent.model.displayName {
              Text("Planner rec: \(recommended)")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text("Assigned: \(agent.model.displayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
              Text("Planner: \(recommended)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .padding(12)
    .background(agentBackgroundColor(for: index, agent: agent))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isAgentRunning(at: index) ? Color.blue : Color.clear, lineWidth: 2)
    )
    .accessibilityIdentifier("agents.chainDetail.agentCard.\(agent.id.uuidString)")
  }

  // MARK: - Agent Status Helpers

  private func isAgentRunning(at index: Int) -> Bool {
    let agent = chain.agents[index]
    return agent.state.isActive
  }

  private func agentStatusColor(for index: Int, agent: Agent) -> Color {
    // Completed
    if agent.state == .complete || chain.results.contains(where: { $0.agentId == agent.id }) {
      return .green
    }

    // Currently running/working
    if agent.state.isActive {
      return .blue
    }

    // Queued (chain is running but this agent hasn't started yet)
    if case .running = chain.state, agent.state == .idle {
      return Color.secondary.opacity(0.3)
    }

    // Failed
    if case .failed = agent.state {
      return .red
    }

    // Idle/Not started
    return Color.secondary.opacity(0.3)
  }

  private func agentNumberColor(for index: Int, agent: Agent) -> Color {
    // Completed or running - white text on colored background
    if agent.state == .complete || chain.results.contains(where: { $0.agentId == agent.id }) || isAgentRunning(at: index) {
      return .white
    }
    // Otherwise secondary text
    return .secondary
  }

  private func agentBackgroundColor(for index: Int, agent: Agent) -> Color {
    // Currently running - light blue background
    if agent.state.isActive {
      return Color.blue.opacity(0.1)
    }

    // Completed - very light green
    if agent.state == .complete || chain.results.contains(where: { $0.agentId == agent.id }) {
      return Color.green.opacity(0.05)
    }

    // Default
    return Color.secondary.opacity(0.1)
  }

  private func selectFolder() {
    if let path = FolderPicker.selectFolder(message: "Select a project folder for this chain") {
      chain.workingDirectory = path
      agentManager.lastUsedWorkingDirectory = path
    }
  }

  private var estimatedCostDisplay: String {
    let totalCost = chain.agents.reduce(0.0) { $0 + $1.model.premiumCost }
    return totalCost.premiumCostDisplay
  }

  private var estimatedCostTier: MCPCopilotModel.CostTier {
    let tiers = chain.agents.map { $0.model.costTier }
    if tiers.contains(.premium) {
      return .premium
    } else if tiers.contains(.standard) {
      return .standard
    } else if tiers.contains(.low) {
      return .low
    } else {
      return .free
    }
  }

  @ViewBuilder
  private var estimatedCostTierBadge: some View {
    let tier = estimatedCostTier
    HStack(spacing: 4) {
      Image(systemName: tier.icon)
      Text(tier.displayName)
        .fontWeight(.semibold)
    }
    .font(.caption)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(tierBackgroundColor(for: tier))
    .foregroundStyle(tierForegroundColor(for: tier))
    .cornerRadius(4)
  }

  private func tierForegroundColor(for tier: MCPCopilotModel.CostTier) -> Color {
    switch tier {
    case .free: return .green
    case .low: return .blue
    case .standard: return .orange
    case .premium: return .red
    }
  }

  private func tierBackgroundColor(for tier: MCPCopilotModel.CostTier) -> Color {
    switch tier {
    case .free: return Color.green.opacity(0.15)
    case .low: return Color.blue.opacity(0.15)
    case .standard: return Color.orange.opacity(0.15)
    case .premium: return Color.red.opacity(0.15)
    }
  }

  private func runChain() async {
    isRunning = true
    defer { isRunning = false }

    errorMessage = nil
    mergeConflicts = []

    let runner = AgentChainRunner(
      agentManager: agentManager,
      cliService: cliService,
      telemetryProvider: MCPTelemetryAdapter(sessionTracker: sessionTracker)
    )
    let summary = await runner.runChain(chain, prompt: prompt)
    mergeConflicts = summary.mergeConflicts
    if let failure = summary.errorMessage {
      errorMessage = failure
    }
  }
}
