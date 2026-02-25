// VMIsolationLinuxView.swift

import SwiftUI

struct VMIsolationLinuxView: View {
  @Environment(VMIsolationService.self) private var service
  @Binding var errorMessage: String?
  @State private var isStartingVM = false
  @State private var isDownloading = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Test Linux VM")
        .font(.headline)

      HStack(spacing: 16) {
        // VM status indicator
        HStack(spacing: 8) {
          Circle()
            .fill(service.isLinuxVMRunning ? .green : .secondary.opacity(0.3))
            .frame(width: 12, height: 12)

          Text(service.isLinuxVMRunning ? "Running" : "Stopped")
            .font(.subheadline)
            .foregroundStyle(service.isLinuxVMRunning ? .primary : .secondary)
        }

        Spacer()

        // Start/Stop button
        if service.isLinuxVMRunning {
          Button {
            Task { @MainActor in
              do {
                try await service.stopLinuxVM()
              } catch {
                errorMessage = "Failed to stop VM: \(error.localizedDescription)"
              }
            }
          } label: {
            Label("Stop VM", systemImage: "stop.fill")
          }
          .buttonStyle(.bordered)
          .tint(.red)
        } else {
          Button {
            Task { @MainActor in
              isStartingVM = true
              do {
                try await service.startLinuxVM()
              } catch {
                errorMessage = "Failed to start VM: \(error.localizedDescription)"
              }
              isStartingVM = false
            }
          } label: {
            if isStartingVM {
              ProgressView()
                .scaleEffect(0.7)
              Text("Starting...")
            } else {
              Label("Start VM", systemImage: "play.fill")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isStartingVM)
        }
      }
      .padding()
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

      // Info and troubleshooting
      VStack(alignment: .leading, spacing: 8) {
        Text("Start a test Linux VM to verify the virtualization setup.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Text("VM start must run on the main actor. The test kernel uses Alpine Linux for VZLinuxBootLoader compatibility.")
          .font(.caption2)
          .foregroundStyle(.secondary)

        HStack(spacing: 12) {
          // Reset button for troubleshooting
          Button {
            Task {
              isDownloading = true
              do {
                try await service.resetLinuxVM()
              } catch {
                errorMessage = "Failed to reset VM: \(error.localizedDescription)"
              }
              isDownloading = false
            }
          } label: {
            Label("Reset Linux VM", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isDownloading || service.isLinuxVMRunning)

          // Path info
          Text("Files: ~/Library/Application Support/Peel/VMs/linux/")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        // Troubleshooting tip
        if !service.isLinuxVMRunning {
          HStack(spacing: 4) {
            Image(systemName: "lightbulb")
              .foregroundStyle(.yellow)
            Text("Tip: If the VM fails to start, try running the app without the debugger (⌘⌥R in Xcode).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}
