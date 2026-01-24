//
//  Workspaces_RootView.swift
//  KitchenSync
//
//  Created on 1/15/26.
//
//  Generic workspace and worktree dashboard.
//  Works with any project - multi-repo workspaces, single repos, or folders.
//

import Foundation
import SwiftUI
import AppKit
import Git

/// Main view for Workspace & Worktree management
struct Workspaces_RootView: View {
  var body: some View {
    WorkspacesDashboardView()
  }
}

// MARK: - macOS Dashboard View

struct WorkspacesDashboardView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(\.modelContext) private var modelContext
  @State private var service = WorkspaceDashboardService()
  @State private var showingAddWorkspace = false
  @State private var showingCreateWorktree = false
  @State private var selectedRepo: WorkspaceRepo?
  @State private var worktreeStatuses: [String: WorktreeStatus] = [:]
  @AppStorage(wrappedValue: .workspaces, "current-tool") private var currentTool: CurrentTool
  @AppStorage("workspaces.selectedWorkspaceName") private var selectedWorkspaceName: String = ""
  @AppStorage("workspaces.selectedRepoName") private var selectedRepoName: String = ""
  @AppStorage("workspaces.selectedWorktreePath") private var selectedWorktreePath: String = ""
  @AppStorage("workspaces.selectedWorktreeName") private var selectedWorktreeName: String = ""
  
  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detailContent
    }
    .navigationSplitViewStyle(.balanced)
    .task {
      service.configure(modelContext: modelContext)
      await service.loadReposAndWorktrees()
      syncSelectionFromStoredValues()
      persistAvailableWorkspaceState()
    }
    .onChange(of: service.workspaces) { _, _ in
      syncSelectionFromStoredValues()
      persistAvailableWorkspaceState()
    }
    .onChange(of: service.repos) { _, _ in
      syncSelectionFromStoredValues()
      persistAvailableWorkspaceState()
    }
    .onChange(of: service.worktrees) { _, _ in
      persistAvailableWorkspaceState()
    }
    .onChange(of: service.selectedWorkspace?.name) { _, newValue in
      let name = newValue ?? ""
      if selectedWorkspaceName != name {
        selectedWorkspaceName = name
      }
    }
    .onChange(of: selectedRepo?.name) { _, newValue in
      let name = newValue ?? ""
      if selectedRepoName != name {
        selectedRepoName = name
      }
    }
    .onChange(of: selectedWorkspaceName) { _, _ in
      syncSelectionFromStoredValues()
    }
    .onChange(of: selectedRepoName) { _, _ in
      syncSelectionFromStoredValues()
    }
    .onChange(of: selectedWorktreePath) { _, _ in
      syncSelectionFromStoredValues()
    }
    .onChange(of: selectedWorktreeName) { _, _ in
      syncSelectionFromStoredValues()
    }
    .onChange(of: mcpServer.lastUIAction?.id) {
      guard let action = mcpServer.lastUIAction else { return }
      switch action.controlId {
      case "workspaces.refresh":
        Task { await service.loadReposAndWorktrees() }
        mcpServer.recordUIActionHandled(action.controlId)
      case "workspaces.addWorkspace":
        showingAddWorkspace = true
        mcpServer.recordUIActionHandled(action.controlId)
      case "workspaces.createWorktree":
        if selectedRepo != nil {
          showingCreateWorktree = true
          mcpServer.recordUIActionHandled(action.controlId)
        }
      case "workspaces.openInVSCode":
        if let repo = selectedRepo {
          Task {
            try? await VSCodeService.shared.open(path: repo.path, newWindow: true)
          }
          mcpServer.recordUIActionHandled(action.controlId)
        }
      case "workspaces.openSelectedWorktree":
        if let worktree = selectedWorktree() {
          openWorktree(worktree)
          mcpServer.recordUIActionHandled(action.controlId)
        }
      case "workspaces.removeSelectedWorktree":
        if let worktree = selectedWorktree() {
          removeWorktree(worktree)
          mcpServer.recordUIActionHandled(action.controlId)
        }
      default:
        break
      }
      mcpServer.lastUIAction = nil
    }
    .sheet(isPresented: $showingAddWorkspace) {
      AddWorkspaceSheet(service: service)
    }
    .sheet(isPresented: $showingCreateWorktree) {
      if let repo = selectedRepo {
        CreateWorktreeSheet(service: service, repo: repo)
      }
    }
    .toolbar {
      ToolSelectionToolbar()
    }
  }
  
  // MARK: - Sidebar
  
  private var sidebar: some View {
    List(selection: Binding(
      get: { service.selectedWorkspace?.id },
      set: { id in
        service.selectedWorkspace = service.workspaces.first { $0.id == id }
        selectedRepo = nil
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
            Button {
              selectedRepo = repo
            } label: {
              RepoRow(
                repo: repo,
                worktreeCount: worktreeCount(for: repo),
                isSelected: selectedRepo?.id == repo.id
              )
            }
            .buttonStyle(.plain)
            .selectionDisabled(true)
            .listRowBackground(
              selectedRepo?.id == repo.id
              ? Color.accentColor.opacity(0.15)
              : Color.clear
            )
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
    service.worktrees.filter { service.repoName(for: $0) == repo.name && !$0.isMain }.count
  }
  
  // MARK: - Worktree List
  
  private var worktreeList: some View {
    VStack(spacing: 0) {
      if let workspace = service.selectedWorkspace {
        WorkspaceHeader(
          workspace: workspace,
          worktreeCount: nonMainWorktrees.count,
          onRefresh: refreshAll,
          onParallelWorktrees: openParallelWorktrees
        )
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
                  trackedWorktreesByPath: service.trackedWorktreesByPath,
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

  @ViewBuilder
  private var detailContent: some View {
    if let repo = selectedRepo {
      repoDetail(repo)
    } else if service.selectedWorkspace != nil {
      worktreeList
    } else {
      emptyState
    }
  }

  private func repoDetail(_ repo: WorkspaceRepo) -> some View {
    VStack(spacing: 0) {
      RepoHeader(
        repo: repo,
        worktreeCount: worktreeCount(for: repo),
        onBack: { selectedRepo = nil },
        onRefresh: refreshAll,
        onParallelWorktrees: openParallelWorktrees
      )
      Divider()
      let repoWorktrees = service.worktrees.filter { service.repoName(for: $0) == repo.name && !$0.isMain }
      if service.isLoading {
        ProgressView("Loading worktrees...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if repoWorktrees.isEmpty {
        ContentUnavailableView {
          Label("No Worktrees for \(repo.name)", systemImage: "arrow.triangle.branch")
        } description: {
          Text("Create a worktree for this repository to work in isolation. Workspaces group repos; worktrees are checkouts.")
        } actions: {
          Button("Create Worktree") {
            selectedRepo = repo
            showingCreateWorktree = true
          }
          .buttonStyle(.borderedProminent)
          Button("Parallel Worktrees") {
            openParallelWorktrees()
          }
          .buttonStyle(.bordered)
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            WorktreeSection(
              repoName: repo.name,
              worktrees: repoWorktrees,
              trackedWorktreesByPath: service.trackedWorktreesByPath,
              statuses: worktreeStatuses,
              onOpen: openWorktree,
              onRemove: removeWorktree,
              onCreate: {
                selectedRepo = repo
                showingCreateWorktree = true
              }
            )
          }
          .padding()
        }
      }
    }
    .task {
      await loadStatuses()
    }
  }
  
  private var nonMainWorktrees: [Git.Worktree] {
    service.worktrees.filter { !$0.isMain }
  }
  
  private var groupedWorktrees: [String: [Git.Worktree]] {
    Dictionary(grouping: nonMainWorktrees, by: { service.repoName(for: $0) ?? "Unknown" })
  }
  
  private var noWorktreesView: some View {
    ContentUnavailableView {
      Label("No Active Worktrees", systemImage: "arrow.triangle.branch")
    } description: {
      Text("Create a worktree to work on a feature in isolation. Workspaces group repos; worktrees are checkouts.")
    } actions: {
      if let repo = service.repos.first {
        Button("Create Worktree") {
          selectedRepo = repo
          showingCreateWorktree = true
        }
        .buttonStyle(.borderedProminent)
      }
      Button("Parallel Worktrees") {
        openParallelWorktrees()
      }
      .buttonStyle(.bordered)
    }
  }
  
  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Workspace Selected", systemImage: "folder.badge.gearshape")
    } description: {
      Text("Add a workspace to manage repositories and worktrees")
    } actions: {
      Button("Add Workspace") {
        showingAddWorkspace = true
      }
      .buttonStyle(.borderedProminent)
      Button("Parallel Worktrees") {
        openParallelWorktrees()
      }
      .buttonStyle(.bordered)
    }
  }
  
  // MARK: - Actions
  
  private func openWorktree(_ worktree: Git.Worktree) {
    Task {
      try? await service.openInVSCode(worktree)
    }
  }
  
  private func removeWorktree(_ worktree: Git.Worktree) {
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

  private func refreshAll() {
    Task {
      await service.loadReposAndWorktrees()
      await loadStatuses()
    }
  }

  private func openParallelWorktrees() {
    UserDefaults.standard.set("infra:parallel-worktrees", forKey: "agents.selectedInfrastructure")
    currentTool = .agents
  }

  private func syncSelectionFromStoredValues() {
    if !selectedWorkspaceName.isEmpty,
       let workspace = service.workspaces.first(where: { $0.name == selectedWorkspaceName }) {
      if service.selectedWorkspace?.id != workspace.id {
        service.selectedWorkspace = workspace
      }
    }

    if !selectedRepoName.isEmpty,
       let repo = service.repos.first(where: { $0.name == selectedRepoName }) {
      if selectedRepo?.id != repo.id {
        selectedRepo = repo
      }
    } else if !selectedRepoName.isEmpty {
      selectedRepo = nil
    }

    let nameMap = worktreeNameMap()
    if !selectedWorktreeName.isEmpty,
       let mappedPath = nameMap[selectedWorktreeName],
       mappedPath != selectedWorktreePath {
      selectedWorktreePath = mappedPath
    } else if !selectedWorktreeName.isEmpty, nameMap[selectedWorktreeName] == nil {
      selectedWorktreeName = ""
    }

    if !selectedWorktreePath.isEmpty,
       let worktree = service.worktrees.first(where: { $0.path == selectedWorktreePath }) {
      let repoName = service.repoName(for: worktree)
      if let repoName,
         let repo = service.repos.first(where: { $0.name == repoName }),
         selectedRepo?.id != repo.id {
        selectedRepo = repo
      }
      let label = nameMap.first(where: { $0.value == worktree.path })?.key ?? worktree.displayName
      if selectedWorktreeName != label {
        selectedWorktreeName = label
      }
    } else if !selectedWorktreePath.isEmpty {
      selectedWorktreePath = ""
    }
  }

  private func selectedWorktree() -> Git.Worktree? {
    guard !selectedWorktreePath.isEmpty else { return nil }
    return service.worktrees.first { $0.path == selectedWorktreePath }
  }

  private func persistAvailableWorkspaceState() {
    let workspaceNames = Array(Set(service.workspaces.map { $0.name })).sorted()
    let repoNames = Array(Set(service.repos.map { $0.name })).sorted()
    let worktreePaths = Array(Set(service.worktrees.map { $0.path })).sorted()
    let nameMap = worktreeNameMap()
    let worktreeNames = Array(nameMap.keys).sorted()
    UserDefaults.standard.set(workspaceNames, forKey: "workspaces.availableNames")
    UserDefaults.standard.set(repoNames, forKey: "workspaces.availableRepoNames")
    UserDefaults.standard.set(worktreePaths, forKey: "workspaces.availableWorktreePaths")
    UserDefaults.standard.set(worktreeNames, forKey: "workspaces.availableWorktreeNames")
    if let data = try? JSONEncoder().encode(nameMap) {
      UserDefaults.standard.set(data, forKey: "workspaces.availableWorktreeNameMap")
    }
  }

  private func worktreeNameMap() -> [String: String] {
    let worktrees = service.worktrees
    var labelCounts: [String: Int] = [:]
    for worktree in worktrees {
      let baseLabel = worktreeAutomationLabel(for: worktree)
      labelCounts[baseLabel, default: 0] += 1
    }

    var map: [String: String] = [:]
    for worktree in worktrees {
      let baseLabel = worktreeAutomationLabel(for: worktree)
      let label = labelCounts[baseLabel, default: 0] > 1
      ? "\(baseLabel) • \(URL(fileURLWithPath: worktree.path).lastPathComponent)"
      : baseLabel
      map[label] = worktree.path
    }
    return map
  }

  private func worktreeAutomationLabel(for worktree: Git.Worktree) -> String {
    if let repoName = service.repoName(for: worktree) {
      return "\(repoName)/\(worktree.displayName)"
    }
    return worktree.displayName
  }
}

// MARK: - Workspace Header

struct WorkspaceHeader: View {
  let workspace: Workspace
  let worktreeCount: Int
  let onRefresh: () -> Void
  let onParallelWorktrees: () -> Void
  
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

      Button {
        onRefresh()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)

      Button {
        onParallelWorktrees()
      } label: {
        Label("Parallel Worktrees", systemImage: "arrow.triangle.branch")
      }
      .buttonStyle(.bordered)
      
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

// MARK: - Repo Header

struct RepoHeader: View {
  let repo: WorkspaceRepo
  let worktreeCount: Int
  let onBack: () -> Void
  let onRefresh: () -> Void
  let onParallelWorktrees: () -> Void
  
  var body: some View {
    HStack {
      Button {
        onBack()
      } label: {
        Label("Workspaces", systemImage: "chevron.left")
      }
      .buttonStyle(.plain)
      
      VStack(alignment: .leading, spacing: 4) {
        Text(repo.name)
          .font(.title2.bold())
        Text(repo.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      
      Spacer()
      
      Button {
        onRefresh()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)

      Button {
        onParallelWorktrees()
      } label: {
        Label("Parallel Worktrees", systemImage: "arrow.triangle.branch")
      }
      .buttonStyle(.bordered)
      
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
  let isSelected: Bool
  
  var body: some View {
    Label {
      HStack {
        Text(repo.name)
        Spacer()
        if worktreeCount > 0 {
          Chip(
            text: "\(worktreeCount)",
            style: .rounded(4),
            font: .caption,
            foreground: .primary,
            background: isSelected ? .white.opacity(0.25) : .blue.opacity(0.2)
          )
        }
      }
    } icon: {
      Image(systemName: repo.isSubmodule ? "arrow.triangle.branch" : "folder")
        .foregroundStyle(.secondary)
    }
    .foregroundStyle(isSelected ? .primary : .primary)
  }
}

// MARK: - Worktree Section

struct WorktreeSection: View {
  let repoName: String
  let worktrees: [Git.Worktree]
  let trackedWorktreesByPath: [String: TrackedWorktree]
  let statuses: [String: WorktreeStatus]
  let onOpen: (Git.Worktree) -> Void
  let onRemove: (Git.Worktree) -> Void
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
          trackedWorktree: trackedWorktreesByPath[worktree.path],
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
  let worktree: Git.Worktree
  let trackedWorktree: TrackedWorktree?
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
            Chip(
              text: "detached",
              style: .rounded(3),
              background: .orange.opacity(0.2),
              horizontalPadding: 4,
              verticalPadding: 1
            )
          }
          
          if let status = status, status.hasUncommittedChanges {
            Chip(
              text: "\(status.changedFileCount) changes",
              style: .rounded(3),
              background: .yellow.opacity(0.2),
              horizontalPadding: 4,
              verticalPadding: 1
            )
          }
        }
        
        Text(worktree.path)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)

        HStack(spacing: 8) {
          if let branch = normalizedBranch(worktree.branch) {
            Label(branch, systemImage: "arrow.branch")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Text(String(worktree.head.prefix(7)))
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
          
          if let status = status, let message = status.lastCommitMessage {
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          if let status = status, let date = status.lastCommitDate {
            Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }

        if let trackedWorktree {
          HStack(spacing: 8) {
            if let purpose = trackedWorktree.purpose {
              Text(purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if trackedWorktree.source != "manual" {
              Label(sourceLabel(for: trackedWorktree.source), systemImage: sourceIcon(for: trackedWorktree.source))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let prNumber = trackedWorktree.linkedPRNumber {
              Text("PR #\(prNumber)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      
      Spacer()
      
      HStack(spacing: 8) {
        Button {
          onOpen()
        } label: {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .buttonStyle(.bordered)
        .help("Open in VS Code")

        Button {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.bordered)
        .help("Show in Finder")
        
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
    .contextMenu {
      Button {
        onOpen()
      } label: {
        Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
      }

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

      Button(role: .destructive) {
        onRemove()
      } label: {
        Label("Delete Worktree", systemImage: "trash")
      }
    }
  }
  
  private var statusColor: Color {
    if let status = status, status.hasUncommittedChanges {
      return .yellow
    }
    return .green
  }

  private func normalizedBranch(_ branch: String?) -> String? {
    guard let branch else { return nil }
    if branch.hasPrefix("refs/heads/") {
      return String(branch.dropFirst("refs/heads/".count))
    }
    return branch
  }

  private func sourceLabel(for source: String) -> String {
    switch source {
    case "pr-review": return "PR Review"
    case "agent": return "Agent"
    default: return source.capitalized
    }
  }

  private func sourceIcon(for source: String) -> String {
    switch source {
    case "pr-review": return "arrow.triangle.branch"
    case "agent": return "sparkles"
    default: return "person"
    }
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
    Form {
      Section {
        Text("Select a folder containing your project or workspace")
          .foregroundStyle(.secondary)
      }
      
      Section {
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
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Add Workspace")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Add") {
          addWorkspace()
        }
        .disabled(selectedPath.isEmpty || isLoading)
      }
    }
    .frame(minWidth: 450, minHeight: 200)
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
    Form {
      Section("Repository") {
        Text(repo.name)
          .font(.headline)
      }
      
      Section("Configuration") {
        TextField("Task Description", text: $description, prompt: Text("e.g., add search caching"))
        TextField("Base Branch", text: $baseBranch, prompt: Text("main"))
        Toggle("Create as detached HEAD (recommended for agent work)", isOn: $createDetached)
        Toggle("Open in VS Code after creation", isOn: $openInVSCode)
      }
      
      if !description.isEmpty {
        Section("Preview") {
          Text("\(service.worktreeRoot)/\(repo.name)-\(safeName)")
            .font(.caption.monospaced())
            .foregroundStyle(.blue)
        }
      }
      
      if let error = errorMessage {
        Section {
          Text(error)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Create Worktree")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          createWorktree()
        }
        .disabled(description.isEmpty || isLoading)
      }
    }
    .frame(minWidth: 450, minHeight: 350)
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

// MARK: - Preview

#Preview {
  Workspaces_RootView()
}
