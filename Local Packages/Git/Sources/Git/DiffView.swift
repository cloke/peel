//
//  Git_DiffView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import PeelUI
import SwiftUI
import OSLog

private struct LineNumberView: View {
  let status: String
  let oldNumber: Int?
  let newNumber: Int?
  
  var body: some View {
    HStack(spacing: 6) {
      Text(oldNumber.map(String.init) ?? "")
        .opacity(status == "+" ? 0 : 1)
      Text(newNumber.map(String.init) ?? "")
        .opacity(status == "-" ? 0 : 1)
    }
    .frame(width: 56, alignment: .trailing)
    .foregroundStyle(.secondary)
  }
}

private struct ChunkHeaderView: View {
  let text: String
  let objectName: String
  let onStageHunk: (() -> Void)?
  let onRevertHunk: (() -> Void)?

  var body: some View {
    HStack(spacing: 4) {
      Text(text)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      if !objectName.isEmpty {
        Text(objectName)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary.opacity(0.7))
      }
      Spacer(minLength: 0)
      if let onStageHunk {
        Button {
          onStageHunk()
        } label: {
          Image(systemName: "plus.square")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Stage this hunk")
      }
      if let onRevertHunk {
        Button {
          onRevertHunk()
        } label: {
          Image(systemName: "arrow.uturn.backward")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Revert this hunk")
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.08))
  }
}

private struct DiffLineRow: View {
  let line: Diff.File.Chunk.Line
  let showLineNumbers: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text(line.status)
        .font(.caption.monospaced())
        .frame(width: 8, alignment: .center)
        .foregroundStyle(statusColor(line.status))
      if showLineNumbers {
        LineNumberView(status: line.status, oldNumber: line.oldLineNumber, newNumber: line.newLineNumber)
          .font(.caption.monospaced())
      }
      Text(line.line)
        .font(.body.monospaced())
        .padding(.vertical, 2)
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "+": return .gitGreen
    case "-": return .red
    default: return .secondary
    }
  }
}

public struct DiffView: View {
  public var diff: Diff
  /// Callback for staging a hunk - receives the patch text
  public var onStageHunk: ((String) async -> Void)?
  /// Callback for reverting a hunk - receives the patch text
  public var onRevertHunk: ((String) async -> Void)?
  
  private let logger = Logger(subsystem: "Peel", category: "Git.DiffRender")
  @State private var expandedFiles: Set<UUID> = []
  
  public init(
    diff: Diff,
    onStageHunk: ((String) async -> Void)? = nil,
    onRevertHunk: ((String) async -> Void)? = nil
  ) {
    self.diff = diff
    self.onStageHunk = onStageHunk
    self.onRevertHunk = onRevertHunk
  }
  
  public var body: some View {
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(diff.files) { file in
          let isExpanded = Binding(
            get: { expandedFiles.contains(file.id) },
            set: { newValue in
              if newValue {
                expandedFiles.insert(file.id)
              } else {
                expandedFiles.remove(file.id)
              }
            }
          )
          VStack(alignment: .leading, spacing: 0) {
            Button {
              isExpanded.wrappedValue.toggle()
            } label: {
              HStack(spacing: 6) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(file.label)
                  .font(.headline)
                  .textSelection(.disabled)
                Spacer(minLength: 0)
              }
              .padding(.vertical, 4)
              .padding(.horizontal, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
              ForEach(file.chunks) { chunk in
                ChunkHeaderView(
                  text: chunk.chunk,
                  objectName: chunk.parsedObjectName,
                  onStageHunk: onStageHunk != nil ? {
                    let patch = chunk.toPatch(oldPath: file.oldPath, newPath: file.newPath)
                    Task { await onStageHunk?(patch) }
                  } : nil,
                  onRevertHunk: onRevertHunk != nil ? {
                    let patch = chunk.toPatch(oldPath: file.oldPath, newPath: file.newPath)
                    Task { await onRevertHunk?(patch) }
                  } : nil
                )
                ForEach(chunk.lines) { line in
                  DiffLineRow(line: line, showLineNumbers: line.lineNumber != 0)
                    .background(lineColor(line.status))
                }
              }
            }
          }
        }
      }
      .textSelection(.enabled)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      #if DEBUG
      logger.notice("Diff render appear (files: \(diff.files.count))")
      #endif
    }
    .onChange(of: diff.id) { _, _ in
      expandedFiles = Set(diff.files.map(\.id))
      let fileCount = diff.files.count
      let chunkCount = diff.files.reduce(0) { $0 + $1.chunks.count }
      let lineCount = diff.files.reduce(0) { total, file in
        total + file.chunks.reduce(0) { $0 + $1.lines.count }
      }
      #if DEBUG
      logger.notice("Diff render update (files: \(fileCount), chunks: \(chunkCount), lines: \(lineCount))")
      #endif
    }
  }
  
  func lineColor(_ symbol: String) -> Color {
    switch symbol {
    case "+": return .gitGreen.opacity(0.15)
    case "-": return .red.opacity(0.12)
    default: return .clear
    }
  }
}


#Preview {
  DiffView(diff: Diff())
}
