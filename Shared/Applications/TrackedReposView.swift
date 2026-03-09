//
//  TrackedReposView.swift
//  Peel
//
//  Manages repos marked as "primary" for periodic auto-pulling.
//  Users can track a remote repo so Peel keeps the local clone fresh.
//

import OSLog
import RAGCore
import SwiftData
import SwiftUI

// MARK: - Tracked Repo Row

struct TrackedRepoRow: View {
  @Bindable var repo: TrackedRemoteRepo
  var deviceState: TrackedRepoDeviceState?
  let isPulling: Bool
  let onPullNow: () -> Void
  let onToggleEnabled: () -> Void
  let onDelete: () -> Void

  @State private var showDetail = false
  @State private var showDeleteConfirm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Header row
      HStack(spacing: 8) {
        Image(systemName: repo.isEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
          .foregroundStyle(repo.isEnabled ? .green : .secondary)
          .font(.title3)

        VStack(alignment: .leading, spacing: 2) {
          Text(repo.name)
            .font(.headline)
          Text(repo.remoteURL)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .layoutPriority(1)

        Spacer(minLength: 4)

        if isPulling {
          ProgressView()
            .controlSize(.small)
        } else {
          statusBadge
        }
      }

      // Detail row
      HStack(spacing: 8) {
        Label(repo.branch, systemImage: "arrow.branch")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Label(pullIntervalText, systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)

        Label(repo.syncMode.displayName, systemImage: repo.syncMode.systemImage)
          .font(.caption)
          .foregroundStyle(repo.syncMode == .pullAndSyncIndex ? .blue : .secondary)

        Spacer(minLength: 4)

        if let lastPull = deviceState?.lastPullAt {
          Text(lastPull, style: .relative)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }

      // Error banner (visible inline instead of tooltip-only)
      if let error = deviceState?.lastPullError, !error.isEmpty {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.red)
          Text(error)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(2)
            .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Pull Now") { onPullNow() }
        .disabled(isPulling)

      Button(repo.isEnabled ? "Disable" : "Enable") { onToggleEnabled() }

      Divider()

      Button { showDetail = true } label: {
        Label("Details…", systemImage: "info.circle")
      }

      Divider()

      if deviceState?.lastPullError != nil {
        Button {
          deviceState?.lastPullError = nil
          deviceState?.lastPullResult = nil
        } label: {
          Label("Clear Error", systemImage: "xmark.circle")
        }

        Divider()
      }

      Button(role: .destructive) { showDeleteConfirm = true } label: {
        Label("Remove Tracking", systemImage: "trash")
      }
    }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) { showDeleteConfirm = true } label: {
        Label("Remove", systemImage: "trash")
      }
    }
    .swipeActions(edge: .leading) {
      Button { onPullNow() } label: {
        Label("Pull", systemImage: "arrow.down.circle")
      }
      .tint(.blue)
    }
    .confirmationDialog("Remove Tracking", isPresented: $showDeleteConfirm) {
      Button("Remove", role: .destructive) { onDelete() }
    } message: {
      Text("Stop tracking \(repo.name)? The local clone will not be deleted.")
    }
    .sheet(isPresented: $showDetail) {
      TrackedRepoDetailSheet(repo: repo, deviceState: deviceState)
    }
  }

  // MARK: - Helpers

  private var pullIntervalText: String {
    let hours = repo.pullIntervalSeconds / 3600
    let minutes = (repo.pullIntervalSeconds % 3600) / 60
    if hours > 0 && minutes > 0 {
      return "\(hours)h \(minutes)m"
    } else if hours > 0 {
      return "\(hours)h"
    } else {
      return "\(minutes)m"
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    if deviceState?.lastPullError != nil && !(deviceState?.lastPullError?.isEmpty ?? true) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .font(.caption)
    } else if let result = deviceState?.lastPullResult {
      if result.starts(with: "updated") {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
          .help(result)
      } else {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(.secondary)
          .font(.caption)
          .help(result)
      }
    } else if !repo.isEnabled {
      Image(systemName: "pause.circle")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }
}

// MARK: - Detail Sheet

struct TrackedRepoDetailSheet: View {
  @Bindable var repo: TrackedRemoteRepo
  var deviceState: TrackedRepoDeviceState?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var branch: String = ""
  @State private var remoteName: String = ""
  @State private var pullIntervalHours: Int = 1
  @State private var pullIntervalMinutes: Int = 0
  @State private var reindexAfterPull: Bool = true
  @State private var syncMode: TrackedRepoSyncMode = .pullAndRebuild

  var body: some View {
    NavigationStack {
      Form {
        Section("Repository") {
          LabeledContent("Name", value: repo.name)
          LabeledContent("Remote URL", value: repo.remoteURL)
          if let path = deviceState?.localPath, !path.isEmpty {
            LabeledContent("Local Path", value: path)
          }
        }

        Section("Pull Settings") {
          TextField("Branch", text: $branch)
          TextField("Remote Name", text: $remoteName)

          HStack {
            Stepper("Hours: \(pullIntervalHours)", value: $pullIntervalHours, in: 0...168)
            Stepper("Minutes: \(pullIntervalMinutes)", value: $pullIntervalMinutes, in: 0...59, step: 5)
          }
        }

        Section {
          Picker("Sync Mode", selection: $syncMode) {
            ForEach(TrackedRepoSyncMode.allCases, id: \.self) { mode in
              Label(mode.displayName, systemImage: mode.systemImage)
                .tag(mode)
            }
          }
          .pickerStyle(.inline)

          Text(syncMode.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
          Text("RAG Index Strategy")
        }

        Section("Status") {
          LabeledContent("Enabled", value: repo.isEnabled ? "Yes" : "No")
          if let lastPull = deviceState?.lastPullAt {
            LabeledContent("Last Pull") {
              Text(lastPull, style: .relative)
            }
          }
          if let result = deviceState?.lastPullResult {
            LabeledContent("Last Result", value: result)
          }
          if let error = deviceState?.lastPullError {
            LabeledContent("Last Error") {
              Text(error)
                .foregroundStyle(.red)
            }
          }
          LabeledContent("Created") {
            Text(repo.createdAt, style: .date)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Tracked Repo Details")
      #if os(macOS)
      .frame(minWidth: 450, minHeight: 400)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
        }
      }
      .onAppear {
        branch = repo.branch
        remoteName = repo.remoteName
        let total = repo.pullIntervalSeconds
        pullIntervalHours = total / 3600
        pullIntervalMinutes = (total % 3600) / 60
        reindexAfterPull = repo.reindexAfterPull
        syncMode = repo.syncMode
      }
    }
  }

  private func save() {
    repo.branch = branch
    repo.remoteName = remoteName
    repo.pullIntervalSeconds = (pullIntervalHours * 3600) + (pullIntervalMinutes * 60)
    repo.reindexAfterPull = syncMode == .pullAndRebuild
    repo.syncMode = syncMode
    repo.touch()
    try? modelContext.save()
    dismiss()
  }
}

// MARK: - Add Tracked Repo Sheet

struct AddTrackedRepoSheet: View {
  @Environment(DataService.self) private var dataService
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(MCPServerService.self) private var mcpServer
  @Query(sort: \TrackedRemoteRepo.name) private var trackedRepos: [TrackedRemoteRepo]

  @State private var localPath = ""
  @State private var name = ""
  @State private var remoteURL = ""
  @State private var branch = "main"
  @State private var remoteName = "origin"
  @State private var pullIntervalHours = 1
  @State private var pullIntervalMinutes = 0
  @State private var syncMode: TrackedRepoSyncMode = .pullAndRebuild
  @State private var errorMessage: String?
  @State private var isDetectingRemote = false
  @State private var showManualEntry = false
  @State private var loadedRepos: [KnownRepo] = []
  @State private var isLoadingRepos = true

  /// A lightweight struct to unify repos from multiple data sources.
  struct KnownRepo: Identifiable, Hashable {
    let id: String   // path-based
    let name: String
    let path: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: KnownRepo, rhs: KnownRepo) -> Bool { lhs.id == rhs.id }
  }

  /// Repos from all app data sources that aren't already tracked.
  private func loadAvailableRepos() async {
    isLoadingRepos = true
    // Collect all paths tracked on this device (from device-local state)
    var trackedPaths = Set<String>()
    for repo in trackedRepos {
      let repoId = repo.id
      let descriptor = FetchDescriptor<TrackedRepoDeviceState>(
        predicate: #Predicate { $0.trackedRepoId == repoId }
      )
      if let state = try? modelContext.fetch(descriptor).first, !state.localPath.isEmpty {
        trackedPaths.insert(state.localPath)
      }
    }
    var seen = Set<String>()
    var repos = [KnownRepo]()

    // 1. RAG-indexed repos (primary source — query store directly)
    if let ragRepos = try? await mcpServer.localRagStore.listRepos() {
      // Group by repoIdentifier and keep only the shortest-path (root) repo per group.
      // This filters out sub-packages (e.g., Local Packages/Git) that share the same
      // repoIdentifier as the parent repo (e.g., kitchen-sink → github.com/cloke/peel).
      var bestByIdentifier: [String: RAGStore.RepoInfo] = [:]
      for repo in ragRepos where !repo.rootPath.isEmpty {
        let key = repo.repoIdentifier ?? repo.id
        if let existing = bestByIdentifier[key] {
          if repo.rootPath.count < existing.rootPath.count {
            bestByIdentifier[key] = repo
          }
        } else {
          bestByIdentifier[key] = repo
        }
      }

      for rag in bestByIdentifier.values {
        let normalized = (rag.rootPath as NSString).standardizingPath
        guard !trackedPaths.contains(rag.rootPath), !trackedPaths.contains(normalized),
              !seen.contains(normalized) else { continue }
        seen.insert(normalized)
        repos.append(KnownRepo(id: normalized, name: rag.name, path: rag.rootPath))
      }
    }

    // 2. SwiftData local repos
    let syncedRepos = (try? modelContext.fetch(FetchDescriptor<SyncedRepository>())) ?? []
    let syncedNamesById = Dictionary(uniqueKeysWithValues: syncedRepos.map { ($0.id, $0.name) })
    let localRepoPaths = dataService.getAllLocalRepositoryPaths(validOnly: true)
    for localRepo in localRepoPaths where !localRepo.localPath.isEmpty {
      let normalized = (localRepo.localPath as NSString).standardizingPath
      guard !trackedPaths.contains(localRepo.localPath), !trackedPaths.contains(normalized),
            !seen.contains(normalized) else { continue }
      seen.insert(normalized)
      let repoName = syncedNamesById[localRepo.repositoryId] ?? URL(fileURLWithPath: normalized).lastPathComponent
      repos.append(KnownRepo(id: normalized, name: repoName, path: normalized))
    }

    // 3. RepoRegistry
    for entry in RepoRegistry.shared.registeredRepos where !entry.localPath.isEmpty {
      let normalized = (entry.localPath as NSString).standardizingPath
      guard !trackedPaths.contains(entry.localPath), !trackedPaths.contains(normalized),
            !seen.contains(normalized) else { continue }
      seen.insert(normalized)
      let repoName = URL(fileURLWithPath: entry.localPath).lastPathComponent
      repos.append(KnownRepo(id: normalized, name: repoName, path: entry.localPath))
    }

    loadedRepos = repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    isLoadingRepos = false
  }

  var body: some View {
    NavigationStack {
      Form {
        if isLoadingRepos {
          Section {
            HStack {
              ProgressView()
                .controlSize(.small)
              Text("Loading repositories…")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
        } else if !loadedRepos.isEmpty {
          Section {
            ForEach(loadedRepos) { repo in
              Button {
                selectKnownRepo(repo)
              } label: {
                HStack {
                  Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                      .font(.body)
                    Text(repo.path)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                      .truncationMode(.head)
                  }
                  Spacer()
                  Image(systemName: "plus.circle")
                    .foregroundStyle(.blue)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          } header: {
            Text("Your Repositories")
          } footer: {
            Text("Select a repo to track, or add one manually below.")
          }
        }

        if !isLoadingRepos && (showManualEntry || loadedRepos.isEmpty) {
          manualEntrySection
        } else {
          Section {
            Button("Enter path manually…") {
              withAnimation { showManualEntry = true }
            }
          }
        }

        if !localPath.isEmpty {
          pullSettingsSection
        }

        if let error = errorMessage {
          Section {
            Text(error)
              .foregroundStyle(.red)
              .font(.caption)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Track Repository")
      #if os(macOS)
      .frame(minWidth: 450, minHeight: 450)
      #endif
      .task { await loadAvailableRepos() }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Track") { addTracking() }
            .disabled(localPath.isEmpty)
        }
      }
    }
  }

  // MARK: - Sections

  private var manualEntrySection: some View {
    Section("Repository") {
      HStack {
        TextField("Local Path", text: $localPath)
        #if os(macOS)
        Button("Browse…") { browseForRepo() }
          .buttonStyle(.bordered)
          .controlSize(.small)
        #endif
      }

      if !localPath.isEmpty {
        Button("Detect Remote") { detectRemote() }
          .disabled(isDetectingRemote)
      }

      TextField("Name", text: $name)
        .help("Display name (auto-detected from path if blank)")

      TextField("Remote URL", text: $remoteURL)
        .help("e.g., https://github.com/org/repo.git")
    }
  }

  private var pullSettingsSection: some View {
    Group {
      Section("Pull Settings") {
        TextField("Branch", text: $branch)
        TextField("Remote Name", text: $remoteName)

        HStack {
          Stepper("Hours: \(pullIntervalHours)", value: $pullIntervalHours, in: 0...168)
          Stepper("Mins: \(pullIntervalMinutes)", value: $pullIntervalMinutes, in: 0...59, step: 5)
        }
      }

      Section {
        Picker("Sync Mode", selection: $syncMode) {
          ForEach(TrackedRepoSyncMode.allCases, id: \.self) { mode in
            Label(mode.displayName, systemImage: mode.systemImage)
              .tag(mode)
          }
        }
        .pickerStyle(.inline)

        Text(syncMode.description)
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("RAG Index Strategy")
      }
    }
  }

  // MARK: - Actions

  private func selectKnownRepo(_ repo: KnownRepo) {
    localPath = repo.path
    name = repo.name
    detectRemote()
  }

  #if os(macOS)
  private func browseForRepo() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "Select a local git repository"
    if panel.runModal() == .OK, let url = panel.url {
      localPath = url.path
      if name.isEmpty {
        name = url.lastPathComponent
      }
      detectRemote()
    }
  }
  #endif

  private func detectRemote() {
    guard !localPath.isEmpty else { return }
    isDetectingRemote = true
    errorMessage = nil

    Task {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["remote", "get-url", remoteName]
      process.currentDirectoryURL = URL(fileURLWithPath: localPath)

      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()

      do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          if !url.isEmpty {
            remoteURL = url
          }
        }
      } catch {
        errorMessage = "Failed to detect remote: \(error.localizedDescription)"
      }

      if name.isEmpty {
        name = URL(fileURLWithPath: localPath).lastPathComponent
      }
      isDetectingRemote = false
    }
  }

  private func addTracking() {
    guard !localPath.isEmpty else { return }
    guard FileManager.default.fileExists(atPath: localPath) else {
      errorMessage = "Path does not exist"
      return
    }

    let resolvedName = name.isEmpty ? URL(fileURLWithPath: localPath).lastPathComponent : name
    let intervalSeconds = (pullIntervalHours * 3600) + (pullIntervalMinutes * 60)

    _ = dataService.trackRemoteRepo(
      remoteURL: remoteURL,
      name: resolvedName,
      localPath: localPath,
      branch: branch,
      remoteName: remoteName,
      pullIntervalSeconds: max(60, intervalSeconds),
      reindexAfterPull: syncMode == .pullAndRebuild,
      syncMode: syncMode
    )
    dismiss()
  }
}

// MARK: - Pull History Row

struct PullHistoryRow: View {
  let entry: PullHistoryEntry

  var body: some View {
    HStack {
      Image(systemName: entry.success ? "checkmark.circle" : "xmark.circle")
        .foregroundStyle(entry.success ? .green : .red)
        .font(.caption)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.repoName)
          .font(.caption)
          .fontWeight(.medium)
        Text(entry.result)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Text(entry.timestamp, style: .relative)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}

// MARK: - Pull Alert Item

struct PullAlertItem {
  let title: String
  let message: String
}

#Preview {
  TrackedRepoRow(
    repo: TrackedRemoteRepo(
      remoteURL: "https://github.com/example/repo.git",
      name: "example-repo",
      branch: "main",
      remoteName: "origin"
    ),
    isPulling: false,
    onPullNow: {},
    onToggleEnabled: {},
    onDelete: {}
  )
  .modelContainer(for: TrackedRemoteRepo.self, inMemory: true)
}
