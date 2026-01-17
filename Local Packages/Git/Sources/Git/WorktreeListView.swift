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
  
  @State private var worktrees: [Worktree] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var showingCreateSheet = false
  @State private var worktreeToDelete: Worktree?
  @State private var isExpanded = true
  
  public init() {}
  
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
            onRefresh: { Task { await loadWorktrees() } }
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
}

struct WorktreeRowView: View {
  let worktree: Worktree
  let repository: Model.Repository
  let onOpenInVSCode: () -> Void
  let onDelete: () -> Void
  let onRefresh: () -> Void
  
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

#Preview {
  List {
    WorktreeListView()
  }
  .environment(Model.Repository(name: "test-repo", path: "/tmp/test-repo"))
}
#endif
