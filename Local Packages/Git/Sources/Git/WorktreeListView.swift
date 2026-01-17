//
//  WorktreeListView.swift
//  Git
//
//  Created by Copilot on 1/7/26.
//

import SwiftUI

#if os(macOS)
import AppKit

/// Find VS Code executable path
private func findVSCode() -> String? {
  let paths = [
    "/usr/local/bin/code",
    "/opt/homebrew/bin/code",
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
    "\(NSHomeDirectory())/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  ]
  
  for path in paths {
    if FileManager.default.fileExists(atPath: path) {
      return path
    }
  }
  return nil
}

/// Open a path in VS Code
private func openInVSCode(_ path: String) throws {
  guard let vscodePath = findVSCode() else {
    throw NSError(domain: "VSCode", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "VS Code is not installed"
    ])
  }
  
  let process = Process()
  process.executableURL = URL(fileURLWithPath: vscodePath)
  process.arguments = ["-n", path]
  try process.run()
}

public struct WorktreeListView: View {
  @Environment(Model.Repository.self) var repository
  let onSelectWorktree: (Worktree) -> Void
  
  @State private var worktrees: [Worktree] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var showingCreateSheet = false
  @State private var worktreeToDelete: Worktree?
  @State private var isExpanded = true
  
  public init(onSelectWorktree: @escaping (Worktree) -> Void = { _ in }) {
    self.onSelectWorktree = onSelectWorktree
  }
  
  public var body: some View {
    Section(isExpanded: $isExpanded) {
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, alignment: .center)
      } else if worktrees.isEmpty {
        Text("No worktrees")
          .foregroundStyle(.secondary)
          .font(.caption)
      } else {
        ForEach(worktrees) { worktree in
          WorktreeRowView(
            worktree: worktree,
            repository: repository,
            onOpenInVSCode: { openWorktreeInVSCode(worktree) },
            onDelete: { worktreeToDelete = worktree },
            onRefresh: { Task { await loadWorktrees() } },
            onSelect: {
              onSelectWorktree(worktree)
            }
          )
        }
      }
      
      // Add worktree button
      Button {
        showingCreateSheet = true
      } label: {
        Label("Add Worktree", systemImage: "plus.rectangle.on.folder")
      }
      .buttonStyle(.plain)
      .tint(.accentColor)
    } header: {
      Button {
        withAnimation { isExpanded.toggle() }
      } label: {
        Label("Worktrees", systemImage: "square.stack.3d.down.right")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
    }
    .task {
      await loadWorktrees()
    }
    .sheet(isPresented: $showingCreateSheet) {
      CreateWorktreeView(
        repository: repository,
        onCreated: {
          Task { await loadWorktrees() }
        }
      )
    }
    .alert("Delete Worktree?", isPresented: .constant(worktreeToDelete != nil)) {
      Button("Cancel", role: .cancel) {
        worktreeToDelete = nil
      }
      Button("Delete", role: .destructive) {
        if let worktree = worktreeToDelete {
          Task { await deleteWorktree(worktree) }
        }
      }
    } message: {
      if let worktree = worktreeToDelete {
        Text("This will remove the worktree at:\n\(worktree.path)")
      }
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }
  
  private func loadWorktrees() async {
    isLoading = true
    do {
      worktrees = try await Commands.Worktree.list(on: repository)
    } catch {
      errorMessage = "Failed to load worktrees: \(error.localizedDescription)"
    }
    isLoading = false
  }
  
  private func openWorktreeInVSCode(_ worktree: Worktree) {
    do {
      try openInVSCode(worktree.path)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func deleteWorktree(_ worktree: Worktree) async {
    do {
      try await Commands.Worktree.remove(path: worktree.path, on: repository)
      await loadWorktrees()
    } catch {
      errorMessage = "Failed to delete worktree: \(error.localizedDescription)"
    }
    worktreeToDelete = nil
  }

  private func toggleLock(_ worktree: Worktree) async {
    do {
      if worktree.isLocked {
        try await Commands.Worktree.unlock(path: worktree.path, on: repository)
      } else {
        try await Commands.Worktree.lock(path: worktree.path, on: repository)
      }
      await loadWorktrees()
    } catch {
      errorMessage = "Failed to update lock: \(error.localizedDescription)"
    }
  }

  private func createBranchFromDetached(_ worktree: Worktree, branchName: String) async {
    let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let worktreeRepo = Model.Repository(name: repository.name, path: worktree.path)
      _ = try await Commands.simple(arguments: ["checkout", "-b", trimmed], in: worktreeRepo)
      await loadWorktrees()
      if let updated = worktrees.first(where: { $0.path == worktree.path }) {
        onSelectWorktree(updated)
      }
    } catch {
      errorMessage = "Failed to create branch: \(error.localizedDescription)"
    }
  }

  private func showInFinder(_ worktree: Worktree) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
  }

  private func copyPath(_ worktree: Worktree) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(worktree.path, forType: .string)
  }

}

struct WorktreeDetailItem: Identifiable, Equatable {
  let id: String
  let worktree: Worktree
  
  init(worktree: Worktree) {
    self.id = worktree.path
    self.worktree = worktree
  }
}

struct WorktreeRowView: View {
  let worktree: Worktree
  let repository: Model.Repository
  let onOpenInVSCode: () -> Void
  let onDelete: () -> Void
  let onRefresh: () -> Void
  let onSelect: () -> Void
  
  var body: some View {
    HStack {
      // Icon
      Image(systemName: worktree.isLocked ? "folder.badge.minus" : "folder.fill")
        .foregroundStyle(iconColor)
      
      // Info
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(worktree.displayName)
            .fontWeight(worktree.isMain ? .semibold : .regular)
          
          if worktree.isMain {
            Text("main")
              .font(.caption2)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.blue.opacity(0.2))
              .foregroundStyle(.blue)
              .clipShape(RoundedRectangle(cornerRadius: 3))
          }
        }
        
        Text(worktree.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      
      Spacer()
      
      // Status badges
      if worktree.isLocked {
        Image(systemName: "lock.fill")
          .foregroundStyle(.orange)
          .help(worktree.lockReason ?? "Locked")
      }
      
      if worktree.isPrunable {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help(worktree.pruneReason ?? "Can be pruned")
      }
      
      // VS Code button (always visible for non-main)
      if !worktree.isMain && findVSCode() != nil {
        Button {
          onOpenInVSCode()
        } label: {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .buttonStyle(.plain)
        .help("Open in VS Code")
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect()
    }
    .contextMenu {
      Button {
        onOpenInVSCode()
      } label: {
        Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
      }
      .disabled(findVSCode() == nil)
      
      Button {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
      } label: {
        Label("Show in Finder", systemImage: "folder")
      }
      
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worktree.path, forType: .string)
      } label: {
        Label("Copy Path", systemImage: "doc.on.doc")
      }
      
      Divider()
      
      if !worktree.isMain {
        if worktree.isLocked {
          Button {
            Task {
              try? await Commands.Worktree.unlock(path: worktree.path, on: repository)
              onRefresh()
            }
          } label: {
            Label("Unlock", systemImage: "lock.open")
          }
        } else {
          Button {
            Task {
              try? await Commands.Worktree.lock(path: worktree.path, on: repository)
              onRefresh()
            }
          } label: {
            Label("Lock", systemImage: "lock")
          }
        }
        
        Divider()
        
        Button(role: .destructive) {
          onDelete()
        } label: {
          Label("Delete Worktree", systemImage: "trash")
        }
      }
    }
  }
  
  private var iconColor: Color {
    if worktree.isMain {
      return .accentColor
    } else if worktree.isLocked {
      return .orange
    } else if worktree.isPrunable {
      return .yellow
    } else {
      return .green
    }
  }
}

struct WorktreeDetailSheet: View {
  let worktree: Worktree
  let repository: Model.Repository
  let onClose: () -> Void
  let onOpenInVSCode: () -> Void
  let onShowInFinder: () -> Void
  let onCopyPath: () -> Void
  let onToggleLock: () -> Void
  let onDelete: () -> Void
  let onCreateBranch: (String) -> Void
  
  @Environment(\.dismiss) private var dismiss
  @State private var isLoading = false
  @State private var hasChanges = false
  @State private var changedFileCount = 0
  @State private var lastCommitMessage: String?
  @State private var lastCommitDate: Date?
  @State private var upstreamName: String?
  @State private var aheadCount = 0
  @State private var behindCount = 0
  @State private var compareURL: URL?
  @State private var loadError: String?
  @State private var showingCreateBranch = false
  
  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text(worktree.displayName)
            .font(.title2.bold())
          Text(worktree.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
        }
        Spacer()
        statusPills
      }
      
      Divider()
      
      VStack(alignment: .leading, spacing: 8) {
        detailRow(title: "HEAD", value: String(worktree.head.prefix(12)))
        detailRow(title: "Branch", value: worktree.branch ?? (worktree.isDetached ? "Detached" : "Main"))
        detailRow(title: "Changes", value: changesSummary)
        detailRow(title: "Last Commit", value: lastCommitSummary)
        detailRow(title: "Upstream", value: upstreamSummary)
        detailRow(title: "Sync", value: aheadBehindSummary)
        if let compareURL {
          detailRow(title: "PR/Compare", value: compareURL.absoluteString)
        }
        if worktree.isLocked {
          detailRow(title: "Lock", value: worktree.lockReason ?? "Locked")
        }
        if worktree.isPrunable {
          detailRow(title: "Prunable", value: worktree.pruneReason ?? "Yes")
        }
        if let loadError {
          Text(loadError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      
      Spacer()
      
      HStack {
        Button("Close") {
          onClose()
        }
        Spacer()
        Button("Copy Path") {
          onCopyPath()
        }
        Button("Show in Finder") {
          onShowInFinder()
        }
        Button("Open in VS Code") {
          onOpenInVSCode()
        }
        if let compareURL {
          Button("Open PR/Compare") {
            NSWorkspace.shared.open(compareURL)
          }
        }
        if worktree.isDetached {
          Button("Create Branch") {
            showingCreateBranch = true
          }
        }
        Button(worktree.isLocked ? "Unlock" : "Lock") {
          onToggleLock()
        }
        .disabled(worktree.isMain)
        Button("Remove", role: .destructive) {
          onDelete()
          dismiss()
        }
        .disabled(worktree.isMain)
      }
    }
    .padding(20)
    .frame(minWidth: 520, minHeight: 320)
    .task(id: worktree.id) {
      await loadStatus()
    }
    .sheet(isPresented: $showingCreateBranch) {
      CreateDetachedBranchSheet(onCreate: { name in
        onCreateBranch(name)
        showingCreateBranch = false
      })
    }
  }
  
  private var statusPills: some View {
    HStack(spacing: 6) {
      if worktree.isMain {
        statusPill("main", color: .blue)
      }
      if worktree.isDetached {
        statusPill("detached", color: .orange)
      }
      if worktree.isLocked {
        statusPill("locked", color: .orange)
      }
      if worktree.isPrunable {
        statusPill("prunable", color: .yellow)
      }
      if worktree.isBare {
        statusPill("bare", color: .gray)
      }
    }
  }
  
  private func statusPill(_ title: String, color: Color) -> some View {
    Text(title)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.2))
      .foregroundStyle(color)
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }
  
  private func detailRow(title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading)
      Text(value)
        .font(.body)
    }
  }

  private var changesSummary: String {
    if isLoading {
      return "Loading…"
    }
    if hasChanges {
      return "\(changedFileCount) file(s) modified"
    }
    return "Clean"
  }

  private var lastCommitSummary: String {
    if isLoading {
      return "Loading…"
    }
    if let message = lastCommitMessage, let date = lastCommitDate {
      let formatter = RelativeDateTimeFormatter()
      let relative = formatter.localizedString(for: date, relativeTo: Date())
      return "\(message) • \(relative)"
    }
    if let message = lastCommitMessage {
      return message
    }
    return "Unavailable"
  }

  private var upstreamSummary: String {
    if isLoading {
      return "Loading…"
    }
    return upstreamName ?? "No upstream"
  }

  private var aheadBehindSummary: String {
    if isLoading {
      return "Loading…"
    }
    if upstreamName == nil {
      return "Not tracking"
    }
    return "Ahead \(aheadCount), Behind \(behindCount)"
  }

  private func loadStatus() async {
    isLoading = true
    loadError = nil
    do {
      let worktreeRepo = Model.Repository(name: repository.name, path: worktree.path)
      let statusLines = try await Commands.simple(arguments: ["status", "--porcelain"], in: worktreeRepo)
      let nonEmptyLines = statusLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      hasChanges = !nonEmptyLines.isEmpty
      changedFileCount = nonEmptyLines.count
      
      let logLines = try await Commands.simple(arguments: ["log", "-1", "--format=%s|%aI"], in: worktreeRepo)
      if let line = logLines.first {
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
          lastCommitMessage = parts[0]
          lastCommitDate = ISO8601DateFormatter().date(from: parts[1])
        } else {
          lastCommitMessage = line
          lastCommitDate = nil
        }
      } else {
        lastCommitMessage = nil
        lastCommitDate = nil
      }

      do {
        let upstreamLines = try await Commands.simple(
          arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
          in: worktreeRepo
        )
        upstreamName = upstreamLines.first
        if upstreamName != nil {
          let counts = try await Commands.simple(
            arguments: ["rev-list", "--left-right", "--count", "HEAD...@{u}"],
            in: worktreeRepo
          )
          if let first = counts.first {
            let parts = first.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if parts.count >= 2 {
              aheadCount = Int(parts[0]) ?? 0
              behindCount = Int(parts[1]) ?? 0
            }
          }
        } else {
          aheadCount = 0
          behindCount = 0
        }
      } catch {
        upstreamName = nil
        aheadCount = 0
        behindCount = 0
      }

      do {
        let remoteLines = try await Commands.simple(arguments: ["remote", "get-url", "origin"], in: worktreeRepo)
        if let remote = remoteLines.first,
           let branch = worktree.branch,
           let slug = parseGitHubSlug(from: remote) {
          compareURL = URL(string: "https://github.com/\(slug)/compare/\(branch)?expand=1")
        } else {
          compareURL = nil
        }
      } catch {
        compareURL = nil
      }
    } catch {
      loadError = "Failed to load status: \(error.localizedDescription)"
    }
    isLoading = false
  }

  private func parseGitHubSlug(from remote: String) -> String? {
    let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("git@") {
      let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { return nil }
      return parts[1].replacingOccurrences(of: ".git", with: "")
    }
    if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
      guard let url = URL(string: trimmed) else { return nil }
      let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if path.isEmpty { return nil }
      return path.replacingOccurrences(of: ".git", with: "")
    }
    return nil
  }
}

struct CreateDetachedBranchSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var branchName: String = ""
  let onCreate: (String) -> Void
  
  var body: some View {
    VStack(spacing: 16) {
      Text("Create Branch")
        .font(.headline)
      TextField("Branch name", text: $branchName)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 320)
      HStack {
        Button("Cancel") {
          dismiss()
        }
        Spacer()
        Button("Create") {
          onCreate(branchName)
          dismiss()
        }
        .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 420)
  }
}

#Preview {
  List {
    WorktreeListView()
  }
  .environment(Model.Repository(name: "test-repo", path: "/tmp/test-repo"))
}
#endif
