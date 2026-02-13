//
//  PRChangedFilesView.swift
//  Github
//
//  Shows files changed in a pull request with expandable inline diffs.
//  Reuses Git.DiffView for rendering patches.
//

import Git
import PeelUI
import SwiftUI

#if os(macOS)
struct PRChangedFilesView: View {
  let owner: String
  let repo: String
  let pullNumber: Int

  @State private var files: [Github.PRFile] = []
  @State private var fileDiffs: [String: Diff] = [:]  // filename -> parsed Diff
  @State private var expandedFiles: Set<String> = []
  @State private var isLoading = true
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header
      HStack {
        Text("Changed Files")
          .font(.headline)

        Spacer()

        if !files.isEmpty {
          fileSummary
        }
      }

      // Content
      if isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading files...")
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
      } else if files.isEmpty {
        Text("No files changed")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      } else {
        // Expand/collapse all
        HStack(spacing: 12) {
          Button {
            if expandedFiles.count == files.count {
              expandedFiles.removeAll()
            } else {
              expandedFiles = Set(files.map(\.filename))
            }
          } label: {
            Text(expandedFiles.count == files.count ? "Collapse All" : "Expand All")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }

        // File rows with inline diffs
        VStack(alignment: .leading, spacing: 0) {
          ForEach(files) { file in
            VStack(alignment: .leading, spacing: 0) {
              FileRow(
                file: file,
                isExpanded: expandedFiles.contains(file.filename)
              ) {
                if expandedFiles.contains(file.filename) {
                  expandedFiles.remove(file.filename)
                } else {
                  expandedFiles.insert(file.filename)
                }
              }

              if expandedFiles.contains(file.filename) {
                if let diff = fileDiffs[file.filename], !diff.files.isEmpty {
                  Git.DiffView(diff: diff)
                    .frame(maxHeight: 400)
                } else if file.patch == nil {
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
                }
              }
            }

            if file.id != files.last?.id {
              Divider()
            }
          }
        }
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
      }
    }
    .task {
      await loadFiles()
    }
  }

  private var fileSummary: some View {
    HStack(spacing: 8) {
      let totalAdditions = files.reduce(0) { $0 + $1.additions }
      let totalDeletions = files.reduce(0) { $0 + $1.deletions }

      Text("\(files.count) file\(files.count == 1 ? "" : "s")")
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

  private func loadFiles() async {
    isLoading = true
    defer { isLoading = false }

    do {
      files = try await Github.pullRequestFiles(owner: owner, repository: repo, number: pullNumber)

      // Parse each file's patch into its own Diff object
      for file in files {
        guard let patch = file.patch else { continue }
        var patchLines = [String]()
        patchLines.append("diff --git a/\(file.filename) b/\(file.filename)")
        if file.status == "added" {
          patchLines.append("new file mode 100644")
        } else if file.status == "removed" {
          patchLines.append("deleted file mode 100644")
        }
        if let prev = file.previous_filename {
          patchLines.append("rename from \(prev)")
          patchLines.append("rename to \(file.filename)")
        }
        patchLines.append("--- a/\(file.previous_filename ?? file.filename)")
        patchLines.append("+++ b/\(file.filename)")
        patchLines.append(contentsOf: patch.components(separatedBy: "\n"))

        fileDiffs[file.filename] = Commands.processDiff(lines: patchLines)
      }
    } catch {
      self.error = "Failed to load files: \(error.localizedDescription)"
    }
  }
}

// MARK: - File Row

private struct FileRow: View {
  let file: Github.PRFile
  let isExpanded: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 8) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 12)

        Image(systemName: statusIcon)
          .font(.caption)
          .foregroundStyle(statusColor)
          .frame(width: 16)

        Text(file.filename)
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

        Text(file.status)
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

  private var statusIcon: String {
    switch file.status {
    case "added": "plus.circle.fill"
    case "removed": "minus.circle.fill"
    case "modified": "pencil.circle.fill"
    case "renamed": "arrow.right.circle.fill"
    case "copied": "doc.on.doc.fill"
    default: "circle.fill"
    }
  }

  private var statusColor: Color {
    switch file.status {
    case "added": .green
    case "removed": .red
    case "modified": .orange
    case "renamed": .blue
    case "copied": .purple
    default: .secondary
    }
  }
}
#endif
