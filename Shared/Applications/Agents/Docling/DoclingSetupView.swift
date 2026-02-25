//
//  DoclingSetupView.swift
//  Peel
//

import SwiftUI

#if os(macOS)
import AppKit

struct DoclingSetupView: View {
  @Binding var pythonPath: String
  let service: DoclingService
  let onError: (String) -> Void

  @State private var isInstalling = false
  @State private var installLog: String?
  @State private var installStatus: String?

  var body: some View {
    ToolSection("Setup") {
      HStack(spacing: 8) {
        Button(isInstalling ? "Installing..." : "Install Docling") {
          Task { await installDocling() }
        }
        .buttonStyle(.bordered)
        .disabled(isInstalling)
        .accessibilityIdentifier("agents.docling.install")

        Button("Open Guide") {
          openGuide()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("agents.docling.openGuide")

        if installStatus != nil {
          installStatusBadge
        }
      }

      if let installLog {
        Text(installLog)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .task {
      let available = await service.isDoclingAvailable(pythonPath: pythonPath.isEmpty ? nil : pythonPath)
      installStatus = available ? "Ready" : "Not installed"
    }
  }

  @MainActor
  private func installDocling() async {
    isInstalling = true
    installLog = nil
    installStatus = "Installing…"
    defer { isInstalling = false }

    do {
      let result = try await service.ensureDoclingInstalled(pythonPath: pythonPath.isEmpty ? nil : pythonPath)
      pythonPath = result.pythonPath
      installLog = result.log
      installStatus = "Installed"
    } catch {
      onError(error.localizedDescription)
      installStatus = "Install failed"
    }
  }

  private func openGuide() {
    let fm = FileManager.default
    var candidates: [String] = []
    candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Docs/guides/DOCLING_POLICY_WORKFLOW.md").path)
    candidates.append(URL(fileURLWithPath: fm.homeDirectoryForCurrentUser.path).appendingPathComponent("code/peel/Docs/guides/DOCLING_POLICY_WORKFLOW.md").path)
    if let bundle = Bundle.main.resourceURL {
      candidates.append(bundle.appendingPathComponent("Docs/guides/DOCLING_POLICY_WORKFLOW.md").path)
    }

    for path in candidates {
      if fm.fileExists(atPath: path) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return
      }
    }

    if let url = URL(string: "https://raw.githubusercontent.com/cloke/peel/main/Docs/guides/DOCLING_POLICY_WORKFLOW.md") {
      NSWorkspace.shared.open(url)
    }
  }

  private var installStatusBadge: some View {
    Group {
      if let status = installStatus {
        switch status {
        case "Ready", "Installed":
          Label(status, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        case "Install failed", "Not installed":
          Label(status, systemImage: "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        case "Installing…":
          Label(status, systemImage: "arrow.clockwise.circle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        default:
          Label(status, systemImage: "questionmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
#endif
