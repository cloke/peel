//
//  WorktreeRowView.swift
//  Git
//
//  Extracted from WorktreeListView.swift
//

import SwiftUI
import PeelUI

import AppKit

struct WorktreeRowView: View {
  let worktree: Worktree
  let repository: Model.Repository
  let canOpenInVSCode: Bool
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
      if !worktree.isMain && canOpenInVSCode {
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
      .disabled(!canOpenInVSCode)
      
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
        
        DestructiveActionButton {
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
