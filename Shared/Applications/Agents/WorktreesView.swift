//
//  WorktreesView.swift
//  Peel
//
//  Created on 1/30/26.
//  Simple view showing all git worktrees across repos.
//

import SwiftUI

struct WorktreesView: View {
  @Environment(MCPServerService.self) private var mcpServer
  
  @State private var worktrees: [WorktreeItem] = []
  @State private var stats: WorktreeStats?
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var selectedWorktree: WorktreeItem?
  
  var body: some View {
    VStack(spacing: 0) {
      // Stats header
      if let stats = stats {
        statsHeader(stats)
        Divider()
      }
      
      // Main content
      if isLoading && worktrees.isEmpty {
        ProgressView("Loading worktrees...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if worktrees.isEmpty {
        emptyState
      } else {
        worktreeList
      }
    }
    .navigationTitle("Worktrees")
    .task {
      await loadWorktrees()
    }
    .refreshable {
      await loadWorktrees()
    }
    #if os(macOS)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await loadWorktrees() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(isLoading)
      }
    }
    #endif
  }
  
  // MARK: - Stats Header
  
  private func statsHeader(_ stats: WorktreeStats) -> some View {
    HStack(spacing: 24) {
      StatItem(
        label: "Worktrees",
        value: "\(stats.totalCount)",
        icon: "arrow.triangle.branch"
      )
      
      StatItem(
        label: "Disk Usage",
        value: formatBytes(stats.totalDiskBytes),
        icon: "internaldrive"
      )
      
      if stats.staleCount > 0 {
        StatItem(
          label: "Stale",
          value: "\(stats.staleCount)",
          icon: "exclamationmark.triangle",
          color: .orange
        )
      }
      
      Spacer()
    }
    .padding()
  }
  
  // MARK: - Empty State
  
  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Worktrees", systemImage: "arrow.triangle.branch")
    } description: {
      Text("Git worktrees will appear here when created by swarm tasks or manually.")
    }
  }
  
  // MARK: - Worktree List
  
  private var worktreeList: some View {
    List(worktrees, selection: $selectedWorktree) { worktree in
      WorktreeRow(worktree: worktree, onDelete: {
        Task { await deleteWorktree(worktree) }
      }, onOpen: {
        openInVSCode(worktree)
      })
      .tag(worktree)
    }
    .listStyle(.inset)
  }
  
  // MARK: - Actions
  
  private func loadWorktrees() async {
    isLoading = true
    errorMessage = nil
    
    // Call worktree.list MCP tool
    do {
      let listResult = await mcpServer.callToolAsync(
        name: "worktree.list",
        arguments: [:]
      )
      
      if let content = listResult.first?.text,
         let data = content.data(using: .utf8),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let worktreesJson = json["worktrees"] as? [[String: Any]] {
        
        worktrees = worktreesJson.compactMap { WorktreeItem(from: $0) }
      }
      
      // Call worktree.stats MCP tool
      let statsResult = await mcpServer.callToolAsync(
        name: "worktree.stats",
        arguments: [:]
      )
      
      if let content = statsResult.first?.text,
         let data = content.data(using: .utf8),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        stats = WorktreeStats(from: json)
      }
      
    } catch {
      errorMessage = error.localizedDescription
    }
    
    isLoading = false
  }
  
  private func deleteWorktree(_ worktree: WorktreeItem) async {
    _ = await mcpServer.callToolAsync(
      name: "worktree.remove",
      arguments: ["path": worktree.path]
    )
    await loadWorktrees()
  }
  
  private func openInVSCode(_ worktree: WorktreeItem) {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Visual Studio Code", worktree.path]
    try? process.run()
    #endif
  }
  
  // MARK: - Helpers
  
  private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

// MARK: - Supporting Types

struct WorktreeItem: Identifiable, Hashable {
  let id: String
  let path: String
  let branch: String
  let repoPath: String
  let diskSizeBytes: Int64
  let isStale: Bool
  let createdAt: Date?
  
  init?(from json: [String: Any]) {
    guard let path = json["path"] as? String,
          let branch = json["branch"] as? String else {
      return nil
    }
    
    self.id = path
    self.path = path
    self.branch = branch
    self.repoPath = json["repoPath"] as? String ?? ""
    self.diskSizeBytes = json["diskSizeBytes"] as? Int64 ?? 0
    self.isStale = json["isStale"] as? Bool ?? false
    
    if let createdStr = json["createdAt"] as? String {
      let formatter = ISO8601DateFormatter()
      self.createdAt = formatter.date(from: createdStr)
    } else {
      self.createdAt = nil
    }
  }
  
  var displayName: String {
    // Extract task ID from path if it looks like task-XXXXXXXX
    let pathComponent = (path as NSString).lastPathComponent
    if pathComponent.hasPrefix("task-") {
      return pathComponent
    }
    return branch
  }
  
  var repoName: String {
    (repoPath as NSString).lastPathComponent
  }
}

struct WorktreeStats {
  let totalCount: Int
  let totalDiskBytes: Int64
  let staleCount: Int
  
  init(from json: [String: Any]) {
    self.totalCount = json["totalCount"] as? Int ?? 0
    self.totalDiskBytes = json["totalDiskBytes"] as? Int64 ?? 0
    self.staleCount = json["staleCount"] as? Int ?? 0
  }
}

// MARK: - Row View

private struct WorktreeRow: View {
  let worktree: WorktreeItem
  let onDelete: () -> Void
  let onOpen: () -> Void
  
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: worktree.isStale ? "exclamationmark.triangle" : "arrow.triangle.branch")
        .foregroundStyle(worktree.isStale ? .orange : .blue)
      
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(worktree.displayName)
            .font(.body)
          
          if worktree.isStale {
            Text("stale")
              .font(.caption2)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.orange.opacity(0.2))
              .foregroundStyle(.orange)
              .clipShape(Capsule())
          }
        }
        
        HStack(spacing: 8) {
          Text(worktree.repoName)
            .foregroundStyle(.secondary)
          
          Text("•")
            .foregroundStyle(.quaternary)
          
          Text(worktree.branch)
            .foregroundStyle(.secondary)
          
          Text("•")
            .foregroundStyle(.quaternary)
          
          Text(formatBytes(worktree.diskSizeBytes))
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
      
      Spacer()
      
      #if os(macOS)
      Button {
        onOpen()
      } label: {
        Image(systemName: "arrow.up.forward.app")
      }
      .buttonStyle(.borderless)
      .help("Open in VS Code")
      
      Button {
        onDelete()
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .help("Delete worktree")
      #endif
    }
    .padding(.vertical, 4)
  }
  
  private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

// MARK: - Stat Item

private struct StatItem: View {
  let label: String
  let value: String
  let icon: String
  var color: Color = .primary
  
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(color)
      
      VStack(alignment: .leading, spacing: 0) {
        Text(value)
          .font(.headline)
          .foregroundStyle(color)
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview {
  WorktreesView()
}
