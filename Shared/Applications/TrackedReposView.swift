//
//  TrackedReposView.swift
//  Peel
//
//  Manages repos marked as "primary" for periodic auto-pulling.
//  Users can track a remote repo so Peel keeps the local clone fresh.
//

import OSLog
import SwiftData
import SwiftUI

// MARK: - Tracked Repos View

struct TrackedReposView: View {
  @Query(sort: \TrackedRemoteRepo.name) private var trackedRepos: [TrackedRemoteRepo]
  @Environment(\.modelContext) private var modelContext
  @State private var showAddSheet = false
  @State private var pullInProgressIds: Set<UUID> = []
  @State private var errorMessage: String?
  @State private var pullAlertItem: PullAlertItem?

  private let scheduler = RepoPullScheduler.shared

  var body: some View {
    NavigationStack {
      Group {
        if trackedRepos.isEmpty {
          emptyState
        } else {
          repoList
        }
      }
      .navigationTitle("Tracked")
      #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button("Add Tracked Repo…") { showAddSheet = true }
            Divider()
            Button("Pull All Due Now") {
              Task { await scheduler.pullDueRepos() }
            }
            .disabled(scheduler.isPulling)
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
      #else
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { showAddSheet = true } label: {
            Image(systemName: "plus")
          }
        }
      }
      #endif
      .sheet(isPresented: $showAddSheet) {
        AddTrackedRepoSheet()
      }
      .alert(
        pullAlertItem?.title ?? "Pull Complete",
        isPresented: Binding(
          get: { pullAlertItem != nil },
          set: { if !$0 { pullAlertItem = nil } }
        )
      ) {
        Button("OK", role: .cancel) { pullAlertItem = nil }
      } message: {
        Text(pullAlertItem?.message ?? "")
      }
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Tracked Repos", systemImage: "arrow.triangle.2.circlepath")
    } description: {
      Text("Track a repo to automatically pull the latest changes on a schedule.")
    } actions: {
      Button("Add Tracked Repo") { showAddSheet = true }
        .buttonStyle(.bordered)
    }
  }

  // MARK: - List

  private var repoList: some View {
    List {
      if scheduler.isPulling {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Pulling repos…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .listRowSeparator(.hidden)
      }

      ForEach(trackedRepos) { repo in
        TrackedRepoRow(
          repo: repo,
          isPulling: pullInProgressIds.contains(repo.id),
          onPullNow: { pullNow(repo) },
          onToggleEnabled: { toggleEnabled(repo) },
          onDelete: { deleteRepo(repo) }
        )
      }

      if !scheduler.pullHistory.isEmpty {
        Section("Recent Activity") {
          ForEach(scheduler.pullHistory.prefix(10)) { entry in
            PullHistoryRow(entry: entry)
          }
        }
      }
    }
    .listStyle(.inset)
  }

  // MARK: - Actions

  private func pullNow(_ repo: TrackedRemoteRepo) {
    guard !pullInProgressIds.contains(repo.id) else { return }
    pullInProgressIds.insert(repo.id)
    Task {
      let result = await scheduler.pullRepoNow(remoteURL: repo.remoteURL)
      pullInProgressIds.remove(repo.id)
      switch result {
      case .upToDate:
        pullAlertItem = PullAlertItem(
          title: repo.name,
          message: "Already up to date."
        )
      case .updated(let sha):
        pullAlertItem = PullAlertItem(
          title: repo.name,
          message: "Updated to \(String(sha.prefix(8)))."
        )
      case .error(let msg):
        pullAlertItem = PullAlertItem(
          title: "Pull Failed",
          message: msg
        )
      case .none:
        pullAlertItem = PullAlertItem(
          title: "Pull Failed",
          message: "Repo not found or scheduler unavailable."
        )
      }
    }
  }

  private func toggleEnabled(_ repo: TrackedRemoteRepo) {
    repo.isEnabled.toggle()
    repo.touch()
    try? modelContext.save()
  }

  private func deleteRepo(_ repo: TrackedRemoteRepo) {
    modelContext.delete(repo)
    try? modelContext.save()
  }
}

// MARK: - Tracked Repo Row

private struct TrackedRepoRow: View {
  @Bindable var repo: TrackedRemoteRepo
  let isPulling: Bool
  let onPullNow: () -> Void
  let onToggleEnabled: () -> Void
  let onDelete: () -> Void

  @State private var showDetail = false
  @State private var showDeleteConfirm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Header row
      HStack {
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
        }

        Spacer()

        if isPulling {
          ProgressView()
            .controlSize(.small)
        } else {
          statusBadge
        }
      }

      // Detail row
      HStack(spacing: 12) {
        Label(repo.branch, systemImage: "arrow.branch")
          .font(.caption)
          .foregroundStyle(.secondary)

        Label(pullIntervalText, systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)

        if repo.reindexAfterPull {
          Label("Re-index", systemImage: "magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if let lastPull = repo.lastPullAt {
          Text(lastPull, style: .relative)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
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
      TrackedRepoDetailSheet(repo: repo)
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
    if let error = repo.lastPullError, !error.isEmpty {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .help(error)
    } else if let result = repo.lastPullResult {
      if result.starts(with: "updated") {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .help(result)
      } else {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(.secondary)
          .help(result)
      }
    } else if !repo.isEnabled {
      Image(systemName: "pause.circle")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Detail Sheet

private struct TrackedRepoDetailSheet: View {
  @Bindable var repo: TrackedRemoteRepo
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var branch: String = ""
  @State private var remoteName: String = ""
  @State private var pullIntervalHours: Int = 1
  @State private var pullIntervalMinutes: Int = 0
  @State private var reindexAfterPull: Bool = true

  var body: some View {
    NavigationStack {
      Form {
        Section("Repository") {
          LabeledContent("Name", value: repo.name)
          LabeledContent("Remote URL", value: repo.remoteURL)
          LabeledContent("Local Path", value: repo.localPath)
        }

        Section("Pull Settings") {
          TextField("Branch", text: $branch)
          TextField("Remote Name", text: $remoteName)

          HStack {
            Stepper("Hours: \(pullIntervalHours)", value: $pullIntervalHours, in: 0...168)
            Stepper("Minutes: \(pullIntervalMinutes)", value: $pullIntervalMinutes, in: 0...59, step: 5)
          }

          Toggle("Re-index RAG after pull", isOn: $reindexAfterPull)
        }

        Section("Status") {
          LabeledContent("Enabled", value: repo.isEnabled ? "Yes" : "No")
          if let lastPull = repo.lastPullAt {
            LabeledContent("Last Pull") {
              Text(lastPull, style: .relative)
            }
          }
          if let result = repo.lastPullResult {
            LabeledContent("Last Result", value: result)
          }
          if let error = repo.lastPullError {
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
      }
    }
  }

  private func save() {
    repo.branch = branch
    repo.remoteName = remoteName
    repo.pullIntervalSeconds = (pullIntervalHours * 3600) + (pullIntervalMinutes * 60)
    repo.reindexAfterPull = reindexAfterPull
    repo.touch()
    try? modelContext.save()
    dismiss()
  }
}

// MARK: - Add Tracked Repo Sheet

private struct AddTrackedRepoSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var localPath = ""
  @State private var name = ""
  @State private var remoteURL = ""
  @State private var branch = "main"
  @State private var remoteName = "origin"
  @State private var pullIntervalHours = 1
  @State private var pullIntervalMinutes = 0
  @State private var reindexAfterPull = true
  @State private var errorMessage: String?
  @State private var isDetectingRemote = false

  var body: some View {
    NavigationStack {
      Form {
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

        Section("Pull Settings") {
          TextField("Branch", text: $branch)
          TextField("Remote Name", text: $remoteName)

          HStack {
            Stepper("Hours: \(pullIntervalHours)", value: $pullIntervalHours, in: 0...168)
            Stepper("Mins: \(pullIntervalMinutes)", value: $pullIntervalMinutes, in: 0...59, step: 5)
          }

          Toggle("Re-index RAG after pull", isOn: $reindexAfterPull)
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
      .frame(minWidth: 450, minHeight: 400)
      #endif
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

  // MARK: - Actions

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

    let tracked = TrackedRemoteRepo(
      remoteURL: remoteURL.isEmpty ? "local://\(localPath)" : remoteURL,
      name: resolvedName,
      localPath: localPath,
      branch: branch,
      remoteName: remoteName,
      pullIntervalSeconds: max(60, intervalSeconds),
      reindexAfterPull: reindexAfterPull
    )
    modelContext.insert(tracked)
    try? modelContext.save()
    dismiss()
  }
}

// MARK: - Pull History Row

private struct PullHistoryRow: View {
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

private struct PullAlertItem {
  let title: String
  let message: String
}

#Preview {
  TrackedReposView()
    .modelContainer(for: TrackedRemoteRepo.self, inMemory: true)
}
