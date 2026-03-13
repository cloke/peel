//
//  WorktreeListView.swift
//  Git
//
//  Created by Copilot on 1/7/26.
//
//  Note: WorktreeRowView, WorktreeDetailSheet, WorktreeDetailItem, and
//  CreateDetachedBranchSheet have been extracted to separate files.
//

import SwiftUI
import PeelUI

import AppKit

public struct WorktreeListView: View {
  @Environment(Model.Repository.self) var repository
  let onSelectWorktree: (Worktree) -> Void
  let onOpenInVSCode: ((String) -> Void)?
  
  @State private var worktrees: [Worktree] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var showingCreateSheet = false
  @State private var worktreeToDelete: Worktree?
  @State private var isExpanded = true
  
  public init(
    onSelectWorktree: @escaping (Worktree) -> Void = { _ in },
    onOpenInVSCode: ((String) -> Void)? = nil
  ) {
    self.onSelectWorktree = onSelectWorktree
    self.onOpenInVSCode = onOpenInVSCode
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
            canOpenInVSCode: onOpenInVSCode != nil,
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
      Label("Worktrees", systemImage: "square.stack.3d.down.right")
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
    .confirmAlert(
      "Delete Worktree?",
      isPresented: Binding(
        get: { worktreeToDelete != nil },
        set: { isPresented in
          if !isPresented { worktreeToDelete = nil }
        }
      ),
      confirmLabel: "Delete",
      confirmRole: .destructive,
      message: worktreeToDelete.map { "This will remove the worktree at:\n\($0.path)" }
    ) {
      if let worktree = worktreeToDelete {
        Task { await deleteWorktree(worktree) }
      }
    }
    .errorAlert(message: $errorMessage)
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
    onOpenInVSCode?(worktree.path)
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

#Preview {
  List {
    WorktreeListView()
  }
  .environment(Model.Repository(name: "test-repo", path: "/tmp/test-repo"))
}
