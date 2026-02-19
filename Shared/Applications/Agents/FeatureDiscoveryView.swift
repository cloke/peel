//
//  FeatureDiscoveryView.swift
//  Peel
//
//  Created on 2/19/26.
//

import SwiftData
import SwiftUI

private let currentFeatureVersion = 1

/// Dismissible feature discovery checklist card shown on fresh install and when new features land.
struct FeatureDiscoveryView: View {
  @Environment(\.modelContext) private var modelContext
  @Query private var checklists: [FeatureDiscoveryChecklist]
  @Query private var syncedRepos: [SyncedRepository]
  @Query private var mcpRuns: [MCPRunRecord]

  @State private var isExpanded = true

  let onAddRepo: () -> Void
  let onRunChain: () -> Void
  let onIndexRAG: () -> Void
  let onConnectMCP: () -> Void
  let onJoinSwarm: () -> Void

  private var checklist: FeatureDiscoveryChecklist? { checklists.first }

  var body: some View {
    Group {
      if let checklist, !checklist.isDismissed {
        card(for: checklist)
      }
    }
    .task {
      ensureChecklist()
    }
  }

  @ViewBuilder
  private func card(for checklist: FeatureDiscoveryChecklist) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        DisclosureGroup(isExpanded: $isExpanded) {
          VStack(spacing: 8) {
            FeatureChecklistRow(
              title: "Add a repository",
              systemImage: "folder.badge.plus",
              isComplete: checklist.didAddRepo
            ) {
              checklist.didAddRepo = true
              checklist.touch()
              onAddRepo()
            }
            FeatureChecklistRow(
              title: "Run an agent chain",
              systemImage: "link",
              isComplete: checklist.didRunChain
            ) {
              checklist.didRunChain = true
              checklist.touch()
              onRunChain()
            }
            FeatureChecklistRow(
              title: "Index a repo for RAG",
              systemImage: "magnifyingglass",
              isComplete: checklist.didIndexRAG
            ) {
              checklist.didIndexRAG = true
              checklist.touch()
              onIndexRAG()
            }
            FeatureChecklistRow(
              title: "Connect MCP",
              systemImage: "server.rack",
              isComplete: checklist.didConnectMCP
            ) {
              checklist.didConnectMCP = true
              checklist.touch()
              onConnectMCP()
            }
            FeatureChecklistRow(
              title: "Join a swarm",
              systemImage: "point.3.connected.trianglepath.dotted",
              isComplete: checklist.didJoinSwarm
            ) {
              checklist.didJoinSwarm = true
              checklist.touch()
              onJoinSwarm()
            }
          }
          .padding(.top, 8)
        } label: {
          HStack {
            Text("Get Started with Peel")
              .font(.headline)
            Spacer()
            Button {
              checklist.isDismissed = true
              checklist.touch()
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss checklist")
          }
        }
      }
    }
  }

  private func ensureChecklist() {
    guard checklists.isEmpty else {
      // Re-show checklist if new features have been added
      if let checklist, checklist.lastSeenFeatureVersion < currentFeatureVersion {
        checklist.isDismissed = false
        checklist.lastSeenFeatureVersion = currentFeatureVersion
        checklist.touch()
      }
      return
    }
    let checklist = FeatureDiscoveryChecklist()
    checklist.lastSeenFeatureVersion = currentFeatureVersion
    // Pre-fill items for returning users
    checklist.didAddRepo = !syncedRepos.isEmpty
    checklist.didRunChain = !mcpRuns.isEmpty
    checklist.didConnectMCP = !mcpRuns.isEmpty
    modelContext.insert(checklist)
  }
}

struct FeatureChecklistRow: View {
  let title: String
  let systemImage: String
  let isComplete: Bool
  let action: () -> Void

  var body: some View {
    HStack {
      Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(isComplete ? .green : .secondary)
      Text(title)
        .strikethrough(isComplete)
        .foregroundStyle(isComplete ? .secondary : .primary)
      Spacer()
      if !isComplete {
        Button("Try it", action: action)
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
  }
}
