//
//  PeonPingSettingsTab.swift
//  Peel
//
//  Settings UI for peon-ping sound notifications.
//

import PeelUI
import SwiftUI

struct PeonPingSettingsTab: View {
  @AppStorage("peonPing.enabled") private var enabled = true
  @AppStorage("peonPing.volume") private var volume: Double = 0.5
  @AppStorage("peonPing.desktopNotifications") private var desktopNotifications = true
  @AppStorage("peonPing.category.greeting") private var greetingEnabled = true
  @AppStorage("peonPing.category.acknowledge") private var acknowledgeEnabled = true
  @AppStorage("peonPing.category.complete") private var completeEnabled = true
  @AppStorage("peonPing.category.error") private var errorEnabled = true
  @AppStorage("peonPing.category.permission") private var permissionEnabled = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // MARK: - Enable / Volume
        SectionCard {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Toggle("Enable Peon Sounds", isOn: $enabled)
                .font(.headline)
              Spacer()
              // Test button
              Button {
                PeonPingService.shared.playPreview(.complete)
              } label: {
                Label("Test", systemImage: "play.fill")
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }

            Text("Play Warcraft III Peon voice lines when agents finish or need attention.")
              .font(.caption)
              .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 12) {
              Image(systemName: volumeIcon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
              Slider(value: $volume, in: 0...1, step: 0.1)
                .disabled(!enabled)
              Text("\(Int(volume * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            }

            Toggle("Desktop notifications when app is in background", isOn: $desktopNotifications)
              .disabled(!enabled)

            Text("Shows a macOS notification banner when Peel is not the active window.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Label("Peon Ping", systemImage: "speaker.wave.2")
        }

        // MARK: - Event Categories
        SectionCard {
          VStack(alignment: .leading, spacing: 8) {
            CategoryToggle(
              label: "Chain Started",
              detail: "\"Ready to work?\" — When a chain or parallel run begins",
              isOn: $greetingEnabled,
              enabled: enabled,
              category: .greeting
            )
            Divider()
            CategoryToggle(
              label: "Task Completed",
              detail: "\"Work, work.\" — When a chain or worktree finishes successfully",
              isOn: $completeEnabled,
              enabled: enabled,
              category: .complete
            )
            Divider()
            CategoryToggle(
              label: "Task Failed",
              detail: "\"Me not that kind of orc!\" — When something goes wrong",
              isOn: $errorEnabled,
              enabled: enabled,
              category: .error
            )
            Divider()
            CategoryToggle(
              label: "Needs Review",
              detail: "\"Something need doing?\" — When a task needs your attention",
              isOn: $permissionEnabled,
              enabled: enabled,
              category: .permission
            )
          }
        } header: {
          Label("Sound Events", systemImage: "list.bullet")
        }

        // MARK: - Attribution
        SectionCard {
          VStack(alignment: .leading, spacing: 4) {
            Text("Sounds from [peon-ping](https://github.com/tonyyont/peon-ping) by @tonyyont (MIT)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("Sound files are property of Blizzard Entertainment.")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        } header: {
          Label("Attribution", systemImage: "info.circle")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentMargins(20, for: .scrollContent)
  }

  private var volumeIcon: String {
    if volume == 0 { return "speaker.slash" }
    if volume < 0.33 { return "speaker.wave.1" }
    if volume < 0.66 { return "speaker.wave.2" }
    return "speaker.wave.3"
  }
}

// MARK: - Category Toggle Row

private struct CategoryToggle: View {
  let label: String
  let detail: String
  @Binding var isOn: Bool
  let enabled: Bool
  let category: PeonSoundCategory

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Toggle(label, isOn: $isOn)
          .disabled(!enabled)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        PeonPingService.shared.playPreview(category)
      } label: {
        Image(systemName: "play.circle")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Preview this sound")
    }
  }
}

#Preview {
  PeonPingSettingsTab()
    .frame(width: 680, height: 500)
}
