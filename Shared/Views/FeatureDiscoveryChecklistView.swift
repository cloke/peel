//
//  FeatureDiscoveryChecklistView.swift
//  Peel
//
//  Dismissible feature-discovery checklist for new users.
//

import SwiftUI

/// A dismissible checklist that guides new users to key Peel features.
@MainActor
struct FeatureDiscoveryChecklistView: View {
  @AppStorage("onboarding.discovered.github") private var discoveredGitHub = false
  @AppStorage("onboarding.discovered.gitrepo") private var discoveredGitRepo = false
  @AppStorage("onboarding.discovered.agents") private var discoveredAgents = false
  @AppStorage("onboarding.discovered.swarm") private var discoveredSwarm = false
  @AppStorage("onboarding.checklistDismissed") private var dismissed = false

  @Environment(\.dismiss) private var dismiss

  private var allDiscovered: Bool {
    discoveredGitHub && discoveredGitRepo && discoveredAgents && discoveredSwarm
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      VStack(alignment: .leading, spacing: 4) {
        Text("Get Started with Peel")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Explore what Peel can do for you.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 16)

      Divider()

      // Checklist items
      VStack(alignment: .leading, spacing: 0) {
        checklistItem(
          title: "Add a Repository",
          description: "Open a local repo or track a remote one.",
          systemImage: "tray.full.fill",
          isDiscovered: $discoveredGitHub
        )
        Divider().padding(.leading, 48)

        checklistItem(
          title: "Explore RAG & Skills",
          description: "Index a repo and see AI-generated insights.",
          systemImage: "sparkle.magnifyingglass",
          isDiscovered: $discoveredGitRepo
        )
        Divider().padding(.leading, 48)

        checklistItem(
          title: "Run an Agent Task",
          description: "Use Activity > Run Task to start an AI chain.",
          systemImage: "cpu.fill",
          isDiscovered: $discoveredAgents
        )
        Divider().padding(.leading, 48)

        checklistItem(
          title: "Open the Swarm Console",
          description: "Activity > Swarm > Open Console to manage workers.",
          systemImage: "network",
          isDiscovered: $discoveredSwarm
        )
      }
      .padding(.vertical, 4)

      Divider()

      // Footer
      HStack {
        if allDiscovered {
          Text("You've discovered all features! 🎉")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("\(discoveredCount)/4 discovered")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button("Dismiss") {
          dismissed = true
          dismiss()
        }
        .buttonStyle(.bordered)
      }
      .padding(16)
    }
    .frame(minWidth: 340, minHeight: 320)
  }

  private var discoveredCount: Int {
    [discoveredGitHub, discoveredGitRepo, discoveredAgents, discoveredSwarm].filter { $0 }.count
  }

  @ViewBuilder
  private func checklistItem(
    title: String,
    description: String,
    systemImage: String,
    isDiscovered: Binding<Bool>
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(.tint)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline)
          .fontWeight(.medium)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        isDiscovered.wrappedValue.toggle()
      } label: {
        Image(systemName: isDiscovered.wrappedValue ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isDiscovered.wrappedValue ? .green : .secondary)
          .font(.title3)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .onTapGesture {
      isDiscovered.wrappedValue = true
    }
  }
}

#Preview {
  FeatureDiscoveryChecklistView()
}
