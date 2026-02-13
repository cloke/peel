//
//  Git_DiffView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import PeelUI
import SwiftUI
import OSLog

// MARK: - Diff Line Gutter

/// Colored gutter indicator alongside each diff line — green bar for additions, red for deletions.
private struct DiffGutterView: View {
  let status: String

  var body: some View {
    Rectangle()
      .fill(gutterColor)
      .frame(width: 3)
  }

  private var gutterColor: Color {
    switch status {
    case "+": return .gitGreen
    case "-": return .red
    default: return .clear
    }
  }
}

// MARK: - Line Numbers

/// Two-column line number display (old / new) with dimmed styling.
private struct LineNumberView: View {
  let status: String
  let oldNumber: Int?
  let newNumber: Int?

  var body: some View {
    HStack(spacing: 0) {
      Text(oldNumber.map(String.init) ?? "")
        .opacity(status == "+" ? 0 : 1)
        .frame(width: 38, alignment: .trailing)
      Text(newNumber.map(String.init) ?? "")
        .opacity(status == "-" ? 0 : 1)
        .frame(width: 38, alignment: .trailing)
    }
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(.tertiary)
  }
}

// MARK: - Chunk (Hunk) Header

/// Styled header for a diff hunk showing the range info, object name, and stage/revert buttons.
private struct ChunkHeaderView: View {
  let text: String
  let objectName: String
  let onStageHunk: (() -> Void)?
  let onRevertHunk: (() -> Void)?

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "ellipsis")
        .font(.system(size: 9))
        .foregroundStyle(.quaternary)

      Text(text)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)

      if !objectName.isEmpty {
        Text(objectName)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary.opacity(0.6))
      }

      Spacer(minLength: 0)

      if let onStageHunk {
        Button {
          onStageHunk()
        } label: {
          Label("Stage hunk", systemImage: "plus.square")
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Stage this hunk")
      }
      if let onRevertHunk {
        Button {
          onRevertHunk()
        } label: {
          Label("Revert hunk", systemImage: "arrow.uturn.backward")
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Revert this hunk")
      }
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06))
    .overlay(alignment: .bottom) {
      Divider().opacity(0.5)
    }
  }
}

// MARK: - Diff Line Row

/// A single line in the diff with gutter, line numbers, status indicator, and code text.
private struct DiffLineRow: View {
  let line: Diff.File.Chunk.Line
  let showLineNumbers: Bool

  var body: some View {
    HStack(spacing: 0) {
      DiffGutterView(status: line.status)

      if showLineNumbers {
        LineNumberView(
          status: line.status,
          oldNumber: line.oldLineNumber,
          newNumber: line.newLineNumber
        )
      }

      Text(statusSymbol)
        .font(.system(size: 11, design: .monospaced))
        .frame(width: 16, alignment: .center)
        .foregroundStyle(statusColor)

      Text(line.line)
        .font(.system(size: 12, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 1)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(lineBackground)
  }

  private var statusSymbol: String {
    switch line.status {
    case "+", "-": return line.status
    default: return " "
    }
  }

  private var statusColor: Color {
    switch line.status {
    case "+": return .gitGreen
    case "-": return .red
    default: return .clear
    }
  }

  private var lineBackground: Color {
    switch line.status {
    case "+": return .gitGreen.opacity(0.10)
    case "-": return .red.opacity(0.08)
    default: return .clear
    }
  }
}

// MARK: - File Header

/// Collapsible file header with filename, diff stats badges (+N/-N), and disclosure chevron.
private struct DiffFileHeaderView: View {
  let file: Diff.File
  let isExpanded: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 8) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 12)

        Image(systemName: fileIcon)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)

        Text(file.label)
          .font(.system(size: 13, weight: .medium))
          .fixedSize(horizontal: true, vertical: false)

        Spacer(minLength: 4)

        if file.additions > 0 {
          Text("+\(file.additions)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.gitGreen)
        }
        if file.deletions > 0 {
          Text("-\(file.deletions)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.red)
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.secondary.opacity(0.04))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private var fileIcon: String {
    let ext = (file.label as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
    case "json", "yaml", "yml", "toml": return "doc.text"
    case "md", "txt": return "doc.plaintext"
    case "png", "jpg", "jpeg", "gif", "svg": return "photo"
    default: return "doc"
    }
  }
}

// MARK: - File Diff Content

/// All chunks (hunks) for a single file, rendered as a continuous block.
private struct DiffFileContentView: View {
  let file: Diff.File
  let onStageHunk: ((String) async -> Void)?
  let onRevertHunk: ((String) async -> Void)?

  var body: some View {
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
      }
    }
  }
}

// MARK: - Main DiffView

public struct DiffView: View {
  public var diff: Diff
  /// Callback for staging a hunk - receives the patch text
  public var onStageHunk: ((String) async -> Void)?
  /// Callback for reverting a hunk - receives the patch text
  public var onRevertHunk: ((String) async -> Void)?
  /// When true, hides the summary bar and file headers, auto-expands all content.
  /// Use for embedding a single-file diff where the caller already shows file info.
  public var compact: Bool

  private let logger = Logger(subsystem: "Peel", category: "Git.DiffRender")
  @State private var expandedFiles: Set<UUID> = []

  public init(
    diff: Diff,
    compact: Bool = false,
    onStageHunk: ((String) async -> Void)? = nil,
    onRevertHunk: ((String) async -> Void)? = nil
  ) {
    self.diff = diff
    self.compact = compact
    self.onStageHunk = onStageHunk
    self.onRevertHunk = onRevertHunk
  }

  public var body: some View {
    ScrollView([.horizontal, .vertical]) {
      VStack(alignment: .leading, spacing: 0) {
        if !compact {
          // Summary bar
          if !diff.files.isEmpty {
            diffSummaryBar
          }
        }

        ForEach(diff.files) { file in
          VStack(alignment: .leading, spacing: 0) {
            if !compact {
              DiffFileHeaderView(
                file: file,
                isExpanded: expandedFiles.contains(file.id)
              ) {
                if expandedFiles.contains(file.id) {
                  expandedFiles.remove(file.id)
                } else {
                  expandedFiles.insert(file.id)
                }
              }
            }

            if compact || expandedFiles.contains(file.id) {
              DiffFileContentView(
                file: file,
                onStageHunk: onStageHunk,
                onRevertHunk: onRevertHunk
              )
            }
          }
        }
      }
      .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      if compact {
        expandedFiles = Set(diff.files.map(\.id))
      }
      #if DEBUG
      logger.notice("Diff render appear (files: \(diff.files.count))")
      #endif
    }
    .onChange(of: diff.id) { _, _ in
      expandedFiles = Set(diff.files.map(\.id))
      #if DEBUG
      let fileCount = diff.files.count
      let chunkCount = diff.files.reduce(0) { $0 + $1.chunks.count }
      let lineCount = diff.files.reduce(0) { total, file in
        total + file.chunks.reduce(0) { $0 + $1.lines.count }
      }
      logger.notice("Diff render update (files: \(fileCount), chunks: \(chunkCount), lines: \(lineCount))")
      #endif
    }
  }

  // MARK: - Summary Bar

  /// Top-level summary showing file count, total additions, and total deletions.
  private var diffSummaryBar: some View {
    let totalAdditions = diff.files.reduce(0) { $0 + $1.additions }
    let totalDeletions = diff.files.reduce(0) { $0 + $1.deletions }

    return HStack(spacing: 12) {
      Label("\(diff.files.count) file\(diff.files.count == 1 ? "" : "s")", systemImage: "doc.on.doc")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      if totalAdditions > 0 {
        Text("+\(totalAdditions)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundColor(.gitGreen)
      }
      if totalDeletions > 0 {
        Text("-\(totalDeletions)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.red)
      }

      Spacer()
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(Color.secondary.opacity(0.03))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}


#Preview {
  DiffView(diff: Diff())
}
