// VMIsolationComponents.swift

import SwiftUI
import PeelUI

// MARK: - Environment Tier Card

struct EnvironmentTierCard: View {
  let environment: ExecutionEnvironment

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: environment.icon)
          .foregroundStyle(colorForEnvironment)
        Text(environment.displayName)
          .fontWeight(.medium)
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Image(systemName: "clock")
            .font(.caption2)
          Text(environment == .host ? "Instant" : "~\(Int(environment.typicalBootTime))s boot")
            .font(.caption)
        }
        .foregroundStyle(.secondary)

        if environment.hasANEAccess {
          HStack {
            Image(systemName: "cpu")
              .font(.caption2)
            Text("ANE + GPU")
              .font(.caption)
          }
          .foregroundStyle(.green)
        }

        if environment.canRunXcode && environment != .host {
          HStack {
            Image(systemName: "hammer")
              .font(.caption2)
            Text("Xcode")
              .font(.caption)
          }
          .foregroundStyle(.blue)
        }
      }

      Text(useCaseText)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  private var colorForEnvironment: Color {
    switch environment {
    case .host: .green
    case .linux: .blue
    case .macos: .purple
    }
  }

  private var useCaseText: String {
    switch environment {
    case .host: "Trusted ops, AI inference"
    case .linux: "Git, scripts, compilers"
    case .macos: "Xcode builds, signing"
    }
  }
}

// MARK: - Setup Status Card

struct SetupStatusCard: View {
  let title: String
  let isReady: Bool
  let readyMessage: String
  let notReadyMessage: String
  let icon: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
          .foregroundStyle(isReady ? .green : .secondary)
        Text(title)
          .fontWeight(.medium)
      }

      Text(isReady ? readyMessage : notReadyMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Pool Card

struct VMPoolCard: View {
  let pool: VMPool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: iconForTier(pool.tier))
          .foregroundStyle(colorForTier(pool.tier))
        Text(pool.tier.description)
          .fontWeight(.medium)
        Spacer()
        Chip(
          text: pool.environment.displayName,
          font: .caption,
          foreground: colorForEnvironment(pool.environment),
          background: colorForEnvironment(pool.environment).opacity(0.2)
        )
      }

      HStack(spacing: 16) {
        VStack(alignment: .leading) {
          Text("Available")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(pool.availableCount)")
            .font(.title3.monospacedDigit())
        }

        VStack(alignment: .leading) {
          Text("Busy")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(pool.busyCount)")
            .font(.title3.monospacedDigit())
        }

        Spacer()

        // Utilization gauge
        Gauge(value: pool.utilizationPercent, in: 0...100) {
          Text("Use")
        } currentValueLabel: {
          Text("\(Int(pool.utilizationPercent))%")
            .font(.caption2)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(pool.utilizationPercent > 80 ? .red : .blue)
        .scaleEffect(0.7)
      }
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  private func iconForTier(_ tier: VMCapabilityTier) -> String {
    switch tier {
    case .readOnlyAnalysis: "eye"
    case .writeAction: "pencil"
    case .networked: "network"
    case .compileFarm: "hammer"
    }
  }

  private func colorForTier(_ tier: VMCapabilityTier) -> Color {
    switch tier {
    case .readOnlyAnalysis: .green
    case .writeAction: .orange
    case .networked: .blue
    case .compileFarm: .purple
    }
  }

  private func colorForEnvironment(_ env: ExecutionEnvironment) -> Color {
    switch env {
    case .host: .green
    case .linux: .blue
    case .macos: .purple
    }
  }
}

// MARK: - Task Row

struct VMTaskRow: View {
  let task: VMTask

  var body: some View {
    HStack {
      Image(systemName: "play.circle.fill")
        .foregroundStyle(.green)

      VStack(alignment: .leading, spacing: 2) {
        Text(task.command)
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
        HStack(spacing: 8) {
          Text(task.capability.description)
          Text("•")
          Text(task.environment.displayName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      ProgressView()
        .scaleEffect(0.7)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Result Row

struct VMTaskResultRow: View {
  let result: VMTaskResult

  var body: some View {
    HStack {
      Image(systemName: result.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(result.exitCode == 0 ? .green : .red)

      VStack(alignment: .leading, spacing: 2) {
        Text("Task \(result.taskId.uuidString.prefix(8))")
          .font(.system(.body, design: .monospaced))
        HStack(spacing: 8) {
          Text(result.environment.displayName)
          if result.bootTime > 0 {
            Text("•")
            Text("Boot: \(String(format: "%.1fs", result.bootTime))")
          }
          Text("•")
          Text("Run: \(String(format: "%.2fs", result.executionTime))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Text("Exit \(result.exitCode)")
        .font(.caption.monospaced())
        .foregroundStyle(result.exitCode == 0 ? Color.secondary : Color.red)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}
