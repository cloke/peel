//
//  WorktreeDetailSheet.swift
//  Git
//
//  Extracted from WorktreeListView.swift
//

import SwiftUI
import PeelUI

#if os(macOS)
import AppKit

/// Model for worktree detail identification
struct WorktreeDetailItem: Identifiable, Equatable {
  let id: String
  let worktree: Worktree
  
  init(worktree: Worktree) {
    self.id = worktree.path
    self.worktree = worktree
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
        DestructiveActionButton {
          onDelete()
          dismiss()
        } label: {
          Text("Remove")
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
#endif
