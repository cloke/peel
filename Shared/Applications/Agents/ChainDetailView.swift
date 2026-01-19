//
//  ChainDetailView.swift
//  KitchenSync
//
//  Created on 1/19/26.
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

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
        #if os(macOS)
        GroupBox {
          HStack {
            Image(systemName: "folder.fill")
              .foregroundStyle(chain.workingDirectory == nil ? .orange : .green)
            Text("Project Folder")
              .font(.subheadline)
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
            }
            Button("Select...") {
              selectFolder()
            }
            .buttonStyle(.bordered)
          }

          if chain.workingDirectory == nil {
            Label("Select a project folder to run the chain", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.top, 4)
          }
        }
        #endif

        Divider()

        // Agents in chain
        VStack(alignment: .leading, spacing: 12) {
          Label("Agents in Chain", systemImage: "list.number").font(.headline)

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
          GroupBox {
            HStack(spacing: 12) {
              Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.purple)
              VStack(alignment: .leading, spacing: 2) {
                Text("MCP Managed")
                  .font(.headline)
                Text("This chain is controlled by MCP. Prompt entry and manual run are hidden.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
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

            Text("This prompt will be sent to Agent 1. Agent 2 will receive Agent 1's output as context.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          // Review loop settings (only show if there's a reviewer in the chain)
          if chain.agents.contains(where: { $0.role == .reviewer }) {
            GroupBox {
              VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                  get: { chain.enableReviewLoop },
                  set: { chain.enableReviewLoop = $0 }
                )) {
                  Label("Enable Review Loop", systemImage: "arrow.triangle.2.circlepath")
                }

                if chain.enableReviewLoop {
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
                  }

                  Text("If reviewer requests changes, re-run implementer with feedback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }

          #if os(macOS)
          // Run button
          HStack {
            Button {
              // Save working directory for next time
              if let dir = chain.workingDirectory {
                agentManager.lastUsedWorkingDirectory = dir
              }
              Task { await runChain() }
            } label: {
              Label(isRunning ? "Running..." : "Run Chain", systemImage: isRunning ? "hourglass" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || prompt.isEmpty || chain.workingDirectory == nil)

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
          #endif
        }

        // Live status panel when running
        if isRunning {
          LiveStatusPanel(chain: chain)
        }

        // Completion banner (show when just completed)
        if case .complete = chain.state, !chain.results.isEmpty {
          GroupBox {
            HStack(spacing: 12) {
              Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
              VStack(alignment: .leading, spacing: 2) {
                Text("Chain Completed")
                  .font(.headline)
                  .foregroundStyle(.green)
                HStack {
                  Text("\(chain.results.count) agents")
                  Text("•")
                  Text(chain.results.reduce(0.0) { $0 + $1.premiumCost }.premiumCostDisplay)
                  if let duration = totalDuration {
                    Text("•")
                    Text(duration)
                  }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer()

              Button {
                // Clear results to run again
                prompt = ""
              } label: {
                Label("New Task", systemImage: "plus")
              }
              .buttonStyle(.bordered)
            }
          }
          .background(Color.green.opacity(0.1))
        }

        // Error
        if let error = errorMessage {
          GroupBox {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if !mergeConflicts.isEmpty {
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Label("Merge Conflicts", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
              Text("Resolve these files, then re-run the reviewer.")
                .font(.caption)
                .foregroundStyle(.secondary)
              ForEach(mergeConflicts, id: \.self) { path in
                Text(path)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }

              #if os(macOS)
              if let path = chain.workingDirectory {
                Button("Open Repo in Finder") {
                  NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
                .buttonStyle(.bordered)
              }
              #endif
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
                      foreground: verdictColor(verdict),
                      background: verdictColor(verdict).opacity(0.15),
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

                GroupBox {
                  ScrollView {
                    Text(result.output)
                      .font(.system(.body, design: .monospaced))
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .textSelection(.enabled)
                  }
                  .frame(maxHeight: 200)
                }
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
      HStack(spacing: 4) {
        Text(agent.model.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)

        if let result = chain.results.first(where: { $0.agentId == agent.id }) {
          Text("•")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(result.premiumCost.premiumMultiplierString()) used")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if agent.state.isActive {
          Text("•")
            .font(.caption)
            .foregroundStyle(.secondary)
          Label(agent.state.displayName, systemImage: agent.state.iconName)
            .font(.caption)
            .foregroundStyle(agent.state.color)
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

  #if os(macOS)
  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a project folder for this chain"
    panel.prompt = "Select"

    if panel.runModal() == .OK, let url = panel.url {
      chain.workingDirectory = url.path
      agentManager.lastUsedWorkingDirectory = url.path
    }
  }

  private func verdictColor(_ verdict: ReviewVerdict) -> Color {
    switch verdict {
    case .approved: return .green
    case .needsChanges: return .orange
    case .rejected: return .red
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
      sessionTracker: sessionTracker
    )
    let summary = await runner.runChain(chain, prompt: prompt)
    mergeConflicts = summary.mergeConflicts
    if let failure = summary.errorMessage {
      errorMessage = failure
    }
  }
  #endif
}
