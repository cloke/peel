// VMIsolationSetupView.swift

import SwiftUI
import PeelUI

struct VMIsolationSetupView: View {
  @Environment(VMIsolationService.self) private var service
  @Binding var missingDependencies: [VMToolDependency]
  @Binding var errorMessage: String?
  @State private var isDownloading = false
  @State private var isInstallingDependencies = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Setup Status")
        .font(.headline)

      HStack(spacing: 20) {
        // Linux VM status
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Image(systemName: service.isLinuxReady ? "checkmark.circle.fill" : "circle.dashed")
              .foregroundStyle(service.isLinuxReady ? .green : .secondary)
            Text("Linux VMs")
              .fontWeight(.medium)

            Chip(
              text: "Recommended",
              foreground: .green,
              background: .green.opacity(0.2)
            )
          }

          if service.isLinuxReady {
            Text("Alpine Linux kernel + initramfs ready")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Downloads Alpine Linux kernel + initramfs")
              .font(.caption)
              .foregroundStyle(.secondary)

            Button {
              Task {
                isDownloading = true
                do {
                  try await service.setupLinuxVM()
                } catch {
                  errorMessage = "Failed to setup Linux VM: \(error.localizedDescription)"
                }
                isDownloading = false
              }
            } label: {
              if isDownloading && !service.isLinuxReady {
                ProgressView()
                  .scaleEffect(0.7)
                Text("Setting up...")
              } else {
                Text("Setup Linux VM")
              }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isDownloading)
          }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

        // macOS VM status
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Image(systemName: service.isMacOSReady ? "checkmark.circle.fill" : "circle.dashed")
              .foregroundStyle(service.isMacOSReady ? .green : .secondary)
            Text("macOS VMs")
              .fontWeight(.medium)
          }

          if service.isMacOSReady {
            Text("Restore image available")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("For Xcode builds only (~13GB)")
              .font(.caption)
              .foregroundStyle(.secondary)

            Button {
              Task {
                isDownloading = true
                do {
                  try await service.downloadMacOSRestoreImage()
                } catch {
                  errorMessage = "Failed to download macOS image: \(error.localizedDescription)"
                }
                isDownloading = false
              }
            } label: {
              if isDownloading && !service.isMacOSReady && service.isLinuxReady {
                ProgressView()
                  .scaleEffect(0.7)
                Text("Downloading...")
              } else {
                Text("Download macOS Image")
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDownloading)
          }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
      }

      // Dependencies
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: missingDependencies.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(missingDependencies.isEmpty ? .green : .orange)
          Text("Dependencies")
            .fontWeight(.medium)
        }

        if missingDependencies.isEmpty {
          Text("All required tools installed")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Missing: \(missingDependencies.map { $0.tool }.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            Task { await installMissingDependencies() }
          } label: {
            if isInstallingDependencies {
              ProgressView()
                .scaleEffect(0.7)
              Text("Installing...")
            } else {
              Text("Install via Homebrew")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(isInstallingDependencies)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

      // Show path info
      if service.isVirtualizationAvailable {
        HStack {
          Image(systemName: "folder")
            .foregroundStyle(.secondary)
          Text("VM files stored in: ~/Library/Application Support/Peel/VMs/")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func installMissingDependencies() async {
    isInstallingDependencies = true
    do {
      try await service.installDependencies(missingDependencies)
      missingDependencies = service.missingToolDependencies()
    } catch {
      errorMessage = "Failed to install dependencies: \(error.localizedDescription)"
    }
    isInstallingDependencies = false
  }
}
