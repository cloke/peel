//
//  RAGReposListView.swift
//  Peel
//
//  Created on 1/25/26.
//

import SwiftUI

/// Displays a list of indexed repositories with their stats
struct RAGReposListView: View {
  let repos: [RAGRepoInfo]
  let currentlyIndexingPath: String?
  let onDelete: (RAGRepoInfo) -> Void
  let onReindex: (RAGRepoInfo) -> Void
  
  var body: some View {
    if repos.isEmpty && currentlyIndexingPath == nil {
      Text("No repositories indexed yet")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(repos) { repo in
          RAGRepoRow(
            repo: repo,
            isIndexing: currentlyIndexingPath == repo.rootPath,
            onDelete: { onDelete(repo) },
            onReindex: { onReindex(repo) }
          )
          
          if repo.id != repos.last?.id {
            Divider()
          }
        }
      }
    }
  }
}

struct RAGRepoRow: View {
  let repo: RAGRepoInfo
  let isIndexing: Bool
  let onDelete: () -> Void
  let onReindex: () -> Void
  
  @State private var isHovering = false
  
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      // Repo icon
      Image(systemName: "folder.fill")
        .font(.title2)
        .foregroundStyle(.blue)
        .frame(width: 32)
      
      // Info
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(repo.name)
            .font(.headline)
          
          if isIndexing {
            ProgressView()
              .scaleEffect(0.6)
          }
        }
        
        Text(repo.rootPath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        
        HStack(spacing: 16) {
          Label("\(repo.fileCount)", systemImage: "doc")
          Label("\(repo.chunkCount)", systemImage: "text.alignleft")
          
          if let lastIndexed = repo.lastIndexedAt {
            Text(lastIndexed, format: .relative(presentation: .named))
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      // Actions (visible on hover)
      if isHovering && !isIndexing {
        HStack(spacing: 8) {
          Button {
            onReindex()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Re-index repository")
          
          Button {
            onDelete()
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
          .help("Remove from index")
        }
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

/// Info about an indexed repository (for UI display)
struct RAGRepoInfo: Identifiable, Sendable {
  let id: String
  let name: String
  let rootPath: String
  let lastIndexedAt: Date?
  let fileCount: Int
  let chunkCount: Int
}

#Preview {
  RAGReposListView(
    repos: [
      RAGRepoInfo(
        id: "1",
        name: "tio-front-end",
        rootPath: "/Users/dev/code/tio-front-end",
        lastIndexedAt: Date().addingTimeInterval(-3600),
        fileCount: 834,
        chunkCount: 2450
      ),
      RAGRepoInfo(
        id: "2", 
        name: "KitchenSink",
        rootPath: "/Users/dev/code/KitchenSink",
        lastIndexedAt: Date().addingTimeInterval(-86400),
        fileCount: 120,
        chunkCount: 380
      )
    ],
    currentlyIndexingPath: nil,
    onDelete: { _ in },
    onReindex: { _ in }
  )
  .padding()
  .frame(width: 500)
}
