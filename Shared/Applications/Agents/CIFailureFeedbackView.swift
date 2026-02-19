//
//  CIFailureFeedbackView.swift
//  Peel
//
//  UI for viewing CI failure patterns and managing guidance.
//

import PeelUI
import SwiftUI
import SwiftData

// MARK: - CI Failure Patterns Panel

struct CIFailurePatternsPanel: View {
  @Environment(CIFailureFeedbackService.self) private var feedbackService
  @State private var selectedPattern: CIFailurePatternSummary?
  @State private var showingGuidanceSheet = false

  let repoPath: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header
      HStack {
        Label("CI Failure Patterns", systemImage: "exclamationmark.triangle")
          .font(.headline)

        Spacer()

        if feedbackService.uniquePatterns > 0 {
          Text("\(feedbackService.uniquePatterns) patterns")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // Stats bar
      statsBar

      Divider()

      // Patterns list
      if feedbackService.recentPatterns.isEmpty {
        ContentUnavailableView {
          Label("No Patterns", systemImage: "checkmark.circle")
        } description: {
          Text("No CI failure patterns recorded yet.")
        }
        .frame(minHeight: 100)
      } else {
        patternsList
      }
    }
    .padding()
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .sheet(isPresented: $showingGuidanceSheet) {
      if let pattern = selectedPattern {
        PatternGuidanceSheet(pattern: pattern)
      }
    }
  }

  @ViewBuilder
  private var statsBar: some View {
    HStack(spacing: 16) {
      StatPill(
        value: "\(feedbackService.totalFailuresRecorded)",
        label: "Total",
        color: .red
      )

      StatPill(
        value: "\(feedbackService.uniquePatterns)",
        label: "Patterns",
        color: .orange
      )

      StatPill(
        value: "\(feedbackService.guidanceGenerated)",
        label: "Guidance",
        color: .green
      )
    }
  }

  @ViewBuilder
  private var patternsList: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        ForEach(feedbackService.recentPatterns) { pattern in
          PatternRow(pattern: pattern) {
            selectedPattern = pattern
            showingGuidanceSheet = true
          } onResolve: {
            Task {
              await feedbackService.resolvePattern(id: pattern.id)
            }
          }
        }
      }
    }
    .frame(maxHeight: 300)
  }
}



// MARK: - Pattern Row

private struct PatternRow: View {
  let pattern: CIFailurePatternSummary
  let onViewGuidance: () -> Void
  let onResolve: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 12) {
      // Type icon
      failureTypeIcon

      // Pattern info
      VStack(alignment: .leading, spacing: 2) {
        Text(pattern.pattern)
          .font(.caption.monospaced())
          .lineLimit(1)

        HStack(spacing: 8) {
          Text(pattern.failureType.rawValue)
            .font(.caption2)
            .foregroundStyle(.secondary)

          Text("•")
            .foregroundStyle(.tertiary)

          Text("\(pattern.occurrenceCount)x")
            .font(.caption2)
            .foregroundStyle(.orange)

          Text("•")
            .foregroundStyle(.tertiary)

          Text(pattern.lastSeen, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      // Actions
      if isHovered {
        HStack(spacing: 4) {
          Button(action: onViewGuidance) {
            Image(systemName: "lightbulb")
          }
          .buttonStyle(.borderless)
          .help("View guidance")

          Button(action: onResolve) {
            Image(systemName: "checkmark.circle")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.green)
          .help("Mark as resolved")
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .onHover { isHovered = $0 }
  }

  @ViewBuilder
  private var failureTypeIcon: some View {
    let (icon, color) = iconAndColor(for: pattern.failureType)

    Image(systemName: icon)
      .font(.caption)
      .foregroundStyle(color)
      .frame(width: 20, height: 20)
      .background(color.opacity(0.1))
      .clipShape(Circle())
  }

  private func iconAndColor(for type: CIFailureType) -> (String, Color) {
    switch type {
    case .build:
      return ("hammer", .orange)
    case .test:
      return ("testtube.2", .red)
    case .lint:
      return ("text.badge.xmark", .yellow)
    case .typecheck:
      return ("chevron.left.forwardslash.chevron.right", .purple)
    case .security:
      return ("shield.slash", .red)
    case .other:
      return ("exclamationmark.circle", .gray)
    }
  }
}

// MARK: - Pattern Guidance Sheet

private struct PatternGuidanceSheet: View {
  @Environment(\.dismiss) private var dismiss
  let pattern: CIFailurePatternSummary

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        // Pattern header
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Pattern")
              .font(.headline)
            Spacer()
          }

          Text(pattern.pattern)
            .font(.body.monospaced())
            .textSelection(.enabled)
        }
        .padding(16)
        .background(.fill.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 10))

        // Stats
        HStack {
          VStack(alignment: .leading) {
            Text("Type")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(pattern.failureType.rawValue.capitalized)
          }

          Spacer()

          VStack(alignment: .center) {
            Text("Occurrences")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\(pattern.occurrenceCount)")
              .font(.title2.bold())
              .foregroundStyle(.orange)
          }

          Spacer()

          VStack(alignment: .trailing) {
            Text("Last Seen")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(pattern.lastSeen, style: .relative)
          }
        }
        .padding(16)
        .background(.fill.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 10))

        // Guidance
        SectionCard("Generated Guidance") {
          if let guidance = pattern.guidance {
            ScrollView {
              Text(guidance)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
          } else {
            Text("No guidance generated yet. Generate guidance to get recommendations for avoiding this failure.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }
      .padding()
      .navigationTitle("CI Failure Pattern")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    .frame(minWidth: 400, minHeight: 400)
  }
}

// MARK: - Compact Failure Indicator

/// Small indicator for MCP run details showing failure count
struct CIFailureIndicator: View {
  let failureCount: Int
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 4) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)

        Text("\(failureCount) CI failures")
          .font(.caption)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.orange.opacity(0.1))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Preview

#Preview("CI Failure Patterns Panel") {
  CIFailurePatternsPanel(repoPath: "/Users/test/repo")
    .frame(width: 400)
    .padding()
}
