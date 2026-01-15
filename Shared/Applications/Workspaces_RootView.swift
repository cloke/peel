//
//  Workspaces_RootView.swift
//  KitchenSync
//
//  Created on 1/15/26.
//
//  Generic workspace and worktree dashboard.
//  Works with any project - multi-repo workspaces, single repos, or folders.
//

import SwiftUI

/// Main view for Workspace & Worktree management
struct Workspaces_RootView: View {
  var body: some View {
    #if os(macOS)
    WorkspacesDashboardView()
    #else
    ContentUnavailableView(
      "Workspaces",
      systemImage: "desktopcomputer",
      description: Text("Workspace management is only available on macOS")
    )
    #endif
  }
}

#if os(macOS)
import AppKit

// MARK: - macOS Dashboard View

struct WorkspacesDashboardView: View {
  @State private var service = WorkspaceDashboardService()
  @State private var showingAddWorkspace = false
  @State private var showingCreateWorktree = false
  @State private var selectedRepo: WorkspaceRepo?
  @State private var worktreeStatuses: [UUID: WorktreeStatus] = [:]
  
  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      if service.selectedWorkspace != nil {
        worktreeList
      } else {
        emptyState
      }
    }
    .navigationSplitViewStyle(.balanced)
    .task {
      await service.loadReposAndWorktrees()
    }
    .sheet(isPresented: $showingAddWorkspace) {
      AddWorkspaceSheet(service: service)
    }
    .sheet(isPresented: $showingCreateWorktree) {
      if let repo = selectedRepo {
        CreateWorktreeSheet(service: service, repo: repo)
      }
    }
  }
  
  // MARK: - Sidebar
  
  private var sidebar: some View {
    List(selection: Binding(
      get: { service.selectedWorkspace?.id },
      set: { id in
        service.selectedWorkspace = service.workspaces.first { $0.id == id }
        Task { await service.loadReposAndWorktrees() }
      }
    )) {
      Section {
        ForEach(service.workspaces) { workspace in
          WorkspaceRow(workspace: workspace)
            .tag(workspace.id)
            .contextMenu {
              Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await service.loadReposAndWorktrees() }
              }
              Divider()
              Button("Remove", systemImage: "trash", role: .destructive) {
                service.removeWorkspace(workspace)
              }
            }
        }
      } header: {
        HStack {
          Text("Workspaces")
          Spacer()
          Button {
            showingAddWorkspace = true
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.plain)
        }
      }
      
      if service.selectedWorkspace != nil, !service.repos.isEmpty {
        Section("Repositories") {
          ForEach(service.repos) { repo in
            RepoRow(repo: repo, worktreeCount: worktreeCount(for: repo))
              .contextMenu {
                Button("Create Worktree...", systemImage: "plus.square") {
                  selectedRepo = repo
                  showingCreateWorktree = true
                }
                Button("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                  Task {
                    try? await VSCodeService.shared.open(path: repo.path, newWindow: true)
                  }
                }
              }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Workspaces")
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          Task { await service.loadReposAndWorktrees() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
      }
    }
  }
  
  private func worktreeCount(for repo: WorkspaceRepo) -> Int {
    service.worktrees.filter { $0.repoName == repo.name && !$0.isMain }.count
  }
  
  // MARK: - Worktree List
  
  private var worktreeList: some View {
    VStack(spacing: 0) {
      if let workspace = service.selectedWorkspace {
        WorkspaceHeader(workspace: workspace, worktreeCount: nonMainWorktrees.count)
      }
      
      Divider()
      
      if service.isLoading {
        ProgressView("Loading worktrees...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if nonMainWorktrees.isEmpty {
        noWorktreesView
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(groupedWorktrees.keys.sorted(), id: \.self) { repoName in
              if let worktrees = groupedWorktrees[repoName] {
                WorktreeSection(
                  repoName: repoName,
                  worktrees: worktrees,
                  statuses: worktreeStatuses,
                  onOpen: openWorktree,
                  onRemove: removeWorktree,
                  onCreate: { 
                    if let repo = service.repos.first(where: { $0.name == repoName }) {
                      selectedRepo = repo
                      showingCreateWorktree = true
                    }
                  }
                )
              }
            }
          }
          .padding()
        }
      }
    }
    .task {
      await loadStatuses()
    }
  }
  
  private var nonMainWorktrees: [WorktreeInfo] {
    service.worktrees.filter { !$0.isMain }
  }
  
  private var groupedWorktrees: [String: [WorktreeInfo]] {
    Dictionary(grouping: nonMainWorktrees, by: \.repoName)
  }
  
  private var noWorktreesView: some View {
    ContentUnavailableView {
      Label("No Active Worktrees", systemImage: "arrow.triangle.branch")
    } description: {
      Text("Create a worktree to work on a feature in isolation")
    } actions: {
      if let repo = service.repos.first {
        Button("Create Worktree") {
          selectedRepo = repo
          showingCreateWorktree = true
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }
  
  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Workspace Selected", systemImage: "folder.badge.gearshape")
    } description: {
      Text("Add a workspace to manage its worktrees")
    } actions: {
      Button("Add Workspace") {
        showingAddWorkspace = true
      }
      .buttonStyle(.borderedProminent)
    }
  }
  
  // MARK: - Actions
  
  private func openWorktree(_ worktree: WorktreeInfo) {
    Task {
      try? await service.openInVSCode(worktree)
    }
  }
  
  private func removeWorktree(_ worktree: WorktreeInfo) {
    Task {
      try? await service.removeWorktree(worktree)
    }
  }
  
  private func loadStatuses() async {
    for worktree in nonMainWorktrees {
      let status = await service.getWorktreeStatus(worktree)
      worktreeStatuses[worktree.id] = status
    }
  }
}

// MARK: - Workspace Header

struct WorkspaceHeader: View {
  let workspace: Workspace
  let worktreeCount: Int
  
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(workspace.name)
          .font(.title2.bold())
        Text(workspace.path)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      VStack(alignment: .trailing, spacing: 4) {
        Label("\(worktreeCount)", systemImage: "arrow.triangle.branch")
          .font(.headline)
        Text("active worktrees")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
  }
}

// MARK: - Workspace Row

struct WorkspaceRow: View {
  let workspace: Workspace
  
  var body: some View {
    Label {
      VStack(alignment: .leading) {
        Text(workspace.name)
        Text(workspace.path)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } icon: {
      Image(systemName: iconName)
        .foregroundStyle(.blue)
    }
  }
  
  private var iconName: String {
    switch workspace.type {
    case .multiRepo: return "square.grid.2x2"
    case .singleRepo: return "folder"
    case .folder: return "folder.badge.questionmark"
    }
  }
}

// MARK: - Repo Row

struct RepoRow: View {
  let repo: WorkspaceRepo
  let worktreeCount: Int
  
  var body: some View {
    Label {
      HStack {
        Text(repo.name)
        Spacer()
        if worktreeCount > 0 {
          Text("\(worktreeCount)")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
      }
    } icon: {
      Image(systemName: repo.isSubmodule ? "arrow.triangle.branch" : "folder")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Worktree Section

struct WorktreeSection: View {
  let repoName: String
  let worktrees: [WorktreeInfo]
  let statuses: [UUID: WorktreeStatus]
  let onOpen: (WorktreeInfo) -> Void
  let onRemove: (WorktreeInfo) -> Void
  let onCreate: () -> Void
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(repoName, systemImage: "folder")
          .font(.headline)
        Spacer()
        Button {
          onCreate()
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .help("Create worktree for \(repoName)")
      }
      
      ForEach(worktrees) { worktree in
        WorktreeCard(
          worktree: worktree,
          status: statuses[worktree.id],
          onOpen: { onOpen(worktree) },
          onRemove: { onRemove(worktree) }
        )
      }
    }
    .padding()
    .background(.background.secondary)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

// MARK: - Worktree Card

struct WorktreeCard: View {
  let worktree: WorktreeInfo
  let status: WorktreeStatus?
  let onOpen: () -> Void
  let onRemove: () -> Void
  
  @State private var isHovering = false
  
  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(statusColor)
        .frame(width: 10, height: 10)
      
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(worktree.displayName)
            .font(.headline)
          
          if worktree.isDetached {
            Text("detached")
              .font(.caption2)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.orange.opacity(0.2))
              .clipShape(RoundedRectangle(cornerRadius: 3))
          }
          
          if let status = status, status.hasUncommittedChanges {
            Text("\(status.changedFileCount) changes")
              .font(.caption2)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.yellow.opacity(0.2))
              .clipShape(RoundedRectangle(cornerRadius: 3))
          }
        }
        
        HStack(spacing: 8) {
          if let branch = worktree.branch {
            Label(branch, systemImage: "arrow.branch")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Text(worktree.commit)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
          
          if let status = status, let message = status.lastCommitMessage {
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
      
      Spacer()
      
      HStack(spacing: 8) {
        Button {
          onOpen()
        } label: {
          Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .buttonStyle(.bordered)
        
        Button(role: .destructive) {
          onRemove()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
      }
      .opacity(isHovering ? 1 : 0.7)
    }
    .padding()
    .background(.background)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    .onHover { hovering in
      isHovering = hovering
    }
  }
  
  private var statusColor: Color {
    if let status = status, status.hasUncommittedChanges {
      return .yellow
    }
    return .green
  }
}

// MARK: - Add Workspace Sheet

struct AddWorkspaceSheet: View {
  @Environment(\.dismiss) var dismiss
  @Bindable var service: WorkspaceDashboardService
  
  @State private var selectedPath: String = ""
  @State private var isLoading = false
  @State private var errorMessage: String?
  
  var body: some View {
    VStack(spacing: 20) {
      Text("Add Workspace")
        .font(.title2.bold())
      
      Text("Select a folder containing your project or workspace")
        .foregroundStyle(.secondary)
      
      HStack {
        TextField("Path", text: $selectedPath)
          .textFieldStyle(.roundedBorder)
        
        Button("Browse...") {
          browseForFolder()
        }
      }
      
      if let error = errorMessage {
        Text(error)
          .foregroundStyle(.red)
          .font(.caption)
      }
      
      HStack {
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        
        Spacer()
        
        Button("Add") {
          addWorkspace()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selectedPath.isEmpty || isLoading)
      }
    }
    .padding(24)
    .frame(width: 450, height: 220)
  }
  
  private func browseForFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a workspace folder"
    
    if panel.runModal() == .OK, let url = panel.url {
      selectedPath = url.path
    }
  }
  
  private func addWorkspace() {
    isLoading = true
    errorMessage = nil
    
    Task {
      do {
        try await service.addWorkspaceFromPath(selectedPath)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
      isLoading = false
    }
  }
}

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
  @Environment(\.dismiss) var dismiss
  @Bindable var service: WorkspaceDashboardService
  let repo: WorkspaceRepo
  
  @State private var description: String = ""
  @State private var baseBranch: String = "main"
  @State private var createDetached: Bool = true
  @State private var openInVSCode: Bool = true
  @State private var isLoading = false
  @State private var errorMessage: String?
  
  var body: some View {
    VStack(spacing: 20) {
      Text("Create Worktree")
        .font(.title2.bold())
      
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Repository")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(repo.name)
            .font(.headline)
        }
        
        VStack(alignment: .leading, spacing: 4) {
          Text("Task Description")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("e.g., add search caching", text: $description)
            .textFieldStyle(.roundedBorder)
        }
        
        VStack(alignment: .leading, spacing: 4) {
          Text("Base Branch")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("main", text: $baseBranch)
            .textFieldStyle(.roundedBorder)
        }
        
        Toggle("Create as detached HEAD (recommended for agent work)", isOn: $createDetached)
          .font(.caption)
        
        Toggle("Open in VS Code after creation", isOn: $openInVSCode)
          .font(.caption)
        
        if !description.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Will create:")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\(service.worktreeRoot)/\(repo.name)-\(safeName)")
              .font(.caption.monospaced())
              .foregroundStyle(.blue)
          }
        }
      }
      
      if let error = errorMessage {
        Text(error)
          .foregroundStyle(.red)
          .font(.caption)
      }
      
      HStack {
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        
        Spacer()
        
        Button("Create") {
          createWorktree()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(description.isEmpty || isLoading)
      }
    }
    .padding(24)
    .frame(width: 450)
  }
  
  private var safeName: String {
    description
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
  }
  
  private func createWorktree() {
    isLoading = true
    errorMessage = nil
    
    Task {
      do {
        let worktree = try await service.createWorktree(
          for: repo,
          description: description,
          baseBranch: baseBranch,
          detached: createDetached
        )
        
        if openInVSCode {
          try await service.openInVSCode(worktree)
        }
        
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
      isLoading = false
    }
  }
}

#endif

// MARK: - Preview

#if os(macOS)
#Preview {
  Workspaces_RootView()
}
#endif
