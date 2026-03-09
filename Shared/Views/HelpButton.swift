//
//  HelpButton.swift
//  Peel
//
//  Contextual help buttons that link to documentation
//

import SwiftUI

// MARK: - Help Topics

/// Topics for contextual help throughout the app
enum HelpTopic: String, CaseIterable {
  case ragIndexing
  case ragSearch
  case swarmSetup
  case swarmInvites
  case swarmWorkers
  case agentRuns
  case chainTemplates
  case promptRules
  case mcpServer
  case piiScrubber
  
  var title: String {
    switch self {
    case .ragIndexing: "RAG Indexing"
    case .ragSearch: "RAG Search"
    case .swarmSetup: "Swarm Setup"
    case .swarmInvites: "Swarm Invites"
    case .swarmWorkers: "Swarm Workers"
    case .agentRuns: "Agent Runs"
    case .chainTemplates: "Chain Templates"
    case .promptRules: "Prompt Rules"
    case .mcpServer: "MCP Server"
    case .piiScrubber: "PII Scrubber"
    }
  }
  
  var summary: String {
    switch self {
    case .ragIndexing:
      "Index your codebase locally for semantic search. Files are chunked, embedded using MLX, and stored in SQLite. Re-indexing preserves AI analysis for unchanged chunks."
    case .ragSearch:
      "Search your indexed code using natural language (vector search) or exact keywords (text search). Results are ranked by relevance using optional reranking."
    case .swarmSetup:
      "Create a distributed swarm to coordinate work across multiple machines. Requires Apple Sign-In for authentication."
    case .swarmInvites:
      "Invite collaborators to your swarm via link. They'll join as pending members until you approve them. Invites can have expiration dates and usage limits."
    case .swarmWorkers:
      "Workers are machines that execute tasks in the swarm. They register with a heartbeat and can be assigned work by the coordinator."
    case .agentRuns:
      "Run agents in isolated git worktrees. Each agent works independently, then changes are reviewed and merged. Supports single and parallel execution."
    case .chainTemplates:
      "Pre-configured agent workflows for common tasks like code review, refactoring, and documentation. Templates define the model, system prompt, and review gates."
    case .promptRules:
      "Global guardrails that apply to all agent chains. Use these to enforce coding standards, prevent certain patterns, or add context about your codebase."
    case .mcpServer:
      "Model Context Protocol server running on port 8765. Enables IDE integration with tools like VS Code, Cursor, and Claude Desktop."
    case .piiScrubber:
      "Detect and redact personally identifiable information from files before sharing or committing. Supports regex patterns and optional NER detection."
    }
  }
  
  /// Anchor in PRODUCT_MANUAL.md (e.g., "#local-rag")
  var docAnchor: String {
    switch self {
    case .ragIndexing, .ragSearch: "#local-rag"
    case .swarmSetup, .swarmInvites, .swarmWorkers: "#distributed-swarm"
    case .agentRuns: "#parallel-worktrees"
    case .chainTemplates: "#template-gallery"
    case .promptRules: "#prompt-rules-guardrails"
    case .mcpServer: "#mcp-server"
    case .piiScrubber: "#pii-scrubber"
    }
  }
  
  /// Full documentation URL
  var docURL: URL? {
    // TODO: Update to hosted docs URL when available
    URL(string: "https://github.com/cloke/peel/blob/main/Docs/PRODUCT_MANUAL.md\(docAnchor)")
  }
}

// MARK: - Help Button

/// A small info button that shows contextual help
struct HelpButton: View {
  let topic: HelpTopic
  
  @State private var showingPopover = false
  
  var body: some View {
    Button {
      showingPopover = true
    } label: {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
        .imageScale(.small)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Help: \(topic.title)")
    .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
      HelpPopoverContent(topic: topic)
    }
  }
}

// MARK: - Help Popover Content

struct HelpPopoverContent: View {
  let topic: HelpTopic
  @Environment(\.dismiss) private var dismiss
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header
      HStack {
        Image(systemName: "lightbulb.fill")
          .foregroundStyle(.yellow)
        Text(topic.title)
          .font(.headline)
        Spacer()
      }
      
      Divider()
      
      // Summary
      Text(topic.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      
      Divider()
      
      // Learn More link
      if let url = topic.docURL {
        HStack {
          Spacer()
          Link(destination: url) {
            HStack(spacing: 4) {
              Text("Learn More")
              Image(systemName: "arrow.up.right.square")
            }
            .font(.callout)
          }
        }
      }
    }
    .padding()
    .frame(width: 300)
  }
}

// MARK: - View Extension for Easy Use

extension View {
  /// Adds a help button to the trailing edge of a view
  func helpButton(_ topic: HelpTopic) -> some View {
    HStack(spacing: 4) {
      self
      HelpButton(topic: topic)
    }
  }
}

// MARK: - Preview

#Preview("Help Button") {
  VStack(spacing: 20) {
    HStack {
      Text("RAG Indexing")
        .font(.headline)
      HelpButton(topic: .ragIndexing)
    }
    
    HStack {
      Text("Swarm Invites")
        .font(.headline)
      HelpButton(topic: .swarmInvites)
    }
    
    // Using the extension
    Text("Agent Runs")
      .font(.headline)
      .helpButton(.agentRuns)
  }
  .padding()
}

#Preview("Help Popover") {
  HelpPopoverContent(topic: .ragIndexing)
}
