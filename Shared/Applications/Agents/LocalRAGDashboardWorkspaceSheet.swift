//
//  LocalRAGDashboardWorkspaceSheet.swift
//  KitchenSync
//
//  Created on 1/31/26.
//

import SwiftUI

struct WorkspaceDetectionDebug: Sendable, Identifiable {
  let id = UUID()
  let rootPath: String
  let resolvedRoot: String
  let readableRoot: Bool
  let scanError: String?
  let directoriesScanned: Int
  let excludedCount: Int
  let gitMarkersFound: Int
  let maxDepthReached: Int
}

struct WorkspaceDetectionResult: Sendable {
  let repos: [String]
  let debug: WorkspaceDetectionDebug
}

struct WorkspaceIndexSheet: View {
  let rootPath: String
  let repos: [String]
  let debugInfo: WorkspaceDetectionDebug?
  @Binding var selectedRepos: Set<String>
  let onCancel: () -> Void
  let onRescan: () -> Void
  let onIndexWorkspace: (Bool) -> Void
  let onIndexSelected: () -> Void
  @State private var confirmWorkspaceIndex = false
  @State private var excludeSubrepos = true
  @State private var didAutoRescan = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Workspace detected")
            .font(.title3)
            .fontWeight(.semibold)

          Text("This folder contains multiple repositories. Index them individually for better results, or index the whole workspace if you prefer.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)

          VStack(alignment: .leading, spacing: 8) {
            Text("Workspace root")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(rootPath)
              .font(.caption)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Select repositories")
                .font(.headline)
              Text("(\(repos.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("All") {
                selectedRepos = Set(repos)
              }
              .buttonStyle(.borderless)
              Button("None") {
                selectedRepos = []
              }
              .buttonStyle(.borderless)
            }

            if repos.isEmpty {
              Text("No git repositories were detected under this folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Button("Rescan") {
                onRescan()
              }
              .buttonStyle(.borderless)
            } else {
              List(repos, id: \.self) { repo in
                Toggle(isOn: Binding(
                  get: { selectedRepos.contains(repo) },
                  set: { isOn in
                    if isOn {
                      selectedRepos.insert(repo)
                    } else {
                      selectedRepos.remove(repo)
                    }
                  }
                )) {
                  Text(repo)
                    .font(.caption)
                    .lineLimit(2)
                }
                .toggleStyle(.checkbox)
              }
              .listStyle(.plain)
              .frame(minHeight: 200, maxHeight: 260)
              .scrollContentBackground(.hidden)
              .clipShape(RoundedRectangle(cornerRadius: 8))
            }
          }

          if let debugInfo {
            DisclosureGroup("Detection details") {
              VStack(alignment: .leading, spacing: 4) {
                Text("Resolved root: \(debugInfo.resolvedRoot)")
                Text("Readable root: \(debugInfo.readableRoot ? "Yes" : "No")")
                if let scanError = debugInfo.scanError {
                  Text("Scan error: \(scanError)")
                }
                Text("Directories scanned: \(debugInfo.directoriesScanned)")
                Text("Excluded folders: \(debugInfo.excludedCount)")
                Text("Git markers found: \(debugInfo.gitMarkersFound)")
                Text("Max depth reached: \(debugInfo.maxDepthReached)")
              }
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }

          if selectedRepos.count > 1 {
            Text("Indexing multiple repositories runs sequentially. It can take a while and may make your Mac feel sluggish while it scans and embeds files.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Divider()

          VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow indexing the entire workspace", isOn: $confirmWorkspaceIndex)
              .toggleStyle(.switch)
            Text("Whole-workspace indexing can be noisy and slower. Prefer sub-repos unless you really need cross-repo context right now.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Toggle("Exclude sub-repos (index only workspace docs)", isOn: $excludeSubrepos)
              .toggleStyle(.switch)
              .disabled(!confirmWorkspaceIndex)
            Text("Keeps the index focused on workspace-level docs and config. Turn off to index everything under the workspace.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.bottom, 8)
      }

      Divider()

      HStack {
        Button("Cancel", action: onCancel)
        Spacer()
        Button("Index Workspace") { onIndexWorkspace(excludeSubrepos) }
          .buttonStyle(.bordered)
          .disabled(!confirmWorkspaceIndex)
        Button("Index Selected", action: onIndexSelected)
          .buttonStyle(.borderedProminent)
          .disabled(selectedRepos.isEmpty)
      }
    }
    .padding(20)
    .onAppear {
      if !didAutoRescan && repos.isEmpty {
        didAutoRescan = true
        onRescan()
      }
    }
  }
}
