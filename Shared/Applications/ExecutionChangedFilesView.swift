//
//  ExecutionChangedFilesView.swift
//  Peel
//
//  Shows files changed by an agent execution with expandable inline diffs.
//  Fetches the unified diff via ParallelWorktreeRunner.diffExecution(),
//  parses it with Git.Commands.processDiff(), and renders with Git.DiffView.
//

import Git
import SwiftUI

struct ExecutionChangedFilesView: View {
  @Bindable var execution: ParallelWorktreeExecution
  let run: ParallelWorktreeRun
  let runner: ParallelWorktreeRunner

  @State private var diff: Diff?
  @State private var isLoading = true
  @State private var error: String?
  @State private var expandedFiles: Set<UUID> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header
      HStack {
        Text("Changed Files")
          .font(.headline)

        Spacer()

        if let diff, !diff.files.isEmpty {
          fileSummary(diff)
        }
      }

      // Content
      if isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading diff...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      } else if let error {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      } else if let diff, !diff.files.isEmpty {
        // Expand/collapse toggle
        HStack(spacing: 12) {
          Button {
            if expandedFiles.count == diff.files.count {
              expandedFiles.removeAll()
            } else {
              expandedFiles = Set(diff.files.map(\.id))
            }
          } label: {
            Text(expandedFiles.count == diff.files.count ? "Collapse All" : "Expand All")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }

        // File list with inline diffs
        VStack(alignment: .leading, spacing: 0) {
          ForEach(diff.files) { file in
            VStack(alignment: .leading, spacing: 0) {
              DiffFileRow(
                file: file,
                isExpanded: expandedFiles.contains(file.id)
              ) {
                if expandedFiles.contains(file.id) {
                  expandedFiles.remove(file.id)
                } else {
                  expandedFiles.insert(file.id)
                }
              }

              if expandedFiles.contains(file.id) {
                if file.chunks.isEmpty {
                  HStack(spacing: 6) {
                    Image(systemName: "doc.zipper")
                      .foregroundStyle(.secondary)
                    Text("Binary file — no diff available")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  .padding(12)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(Color.secondary.opacity(0.04))
                } else {
                  let singleFileDiff = Diff(files: [file])
                  Git.DiffView(diff: singleFileDiff, compact: true)
                    .frame(maxHeight: 400)
                }
              }
            }

            if file.id != diff.files.last?.id {
              Divider()
            }
          }
        }
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
      } else {
        Text("No code changes in this execution")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      }
    }
    .task {
      await loadDiff()
    }
  }

  private func fileSummary(_ diff: Diff) -> some View {
    HStack(spacing: 8) {
      let totalAdditions = diff.files.reduce(0) { $0 + $1.additions }
      let totalDeletions = diff.files.reduce(0) { $0 + $1.deletions }

      Text("\(diff.files.count) file\(diff.files.count == 1 ? "" : "s")")
        .font(.caption)
        .foregroundStyle(.secondary)

      if totalAdditions > 0 {
        Text("+\(totalAdditions)")
          .font(.caption.monospaced())
          .foregroundStyle(.green)
      }
      if totalDeletions > 0 {
        Text("-\(totalDeletions)")
          .font(.caption.monospaced())
          .foregroundStyle(.red)
      }
    }
  }

  private func loadDiff() async {
    isLoading = true
    defer { isLoading = false }

    let rawDiff = await runner.diffExecution(execution, in: run)

    if rawDiff.hasPrefix("(no ") {
      // No diff available — branch not started or no changes
      diff = Diff()
      return
    }

    let lines = rawDiff.components(separatedBy: "\n")
    if lines.count > 5000 {
      // Very large diff — truncate to avoid UI lag
      let truncated = Array(lines.prefix(5000))
      diff = Commands.processDiff(lines: truncated)
      error = "Showing first 5000 lines. Full diff has \(lines.count) lines."
    } else {
      diff = Commands.processDiff(lines: lines)
    }
  }
}

// MARK: - Diff File Row

/// A row showing a single file in the changed files list.
private struct DiffFileRow: View {
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
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 16)

        Text(file.label)
          .font(.system(size: 13, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: 4)

        HStack(spacing: 6) {
          if file.additions > 0 {
            Text("+\(file.additions)")
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.green)
          }
          if file.deletions > 0 {
            Text("-\(file.deletions)")
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.red)
          }
        }

        // Status indicator based on file content
        Text(fileStatus)
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(statusColor.opacity(0.15))
          .foregroundStyle(statusColor)
          .clipShape(Capsule())
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var fileStatus: String {
    if file.deletions == 0 && file.additions > 0 { return "added" }
    if file.additions == 0 && file.deletions > 0 { return "deleted" }
    return "modified"
  }

  private var statusColor: Color {
    if file.deletions == 0 && file.additions > 0 { return .green }
    if file.additions == 0 && file.deletions > 0 { return .red }
    return .orange
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
