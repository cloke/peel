//
//  ConflictResolutionView.swift
//  Peel
//
//  Created on 2/19/26.
//

import SwiftUI

/// Displays the conflicted files for a parallel worktree execution and lets the
/// user choose how to resolve each one before committing the merge.
struct ConflictResolutionView: View {
  let execution: ParallelWorktreeExecution
  let run: ParallelWorktreeRun
  let runner: ParallelWorktreeRunner

  @Environment(\.dismiss) private var dismiss
  @State private var resolutions: [String: ConflictResolution] = [:]
  @State private var selectedFile: MergeConflictFile?
  @State private var fileContents: [String: String] = [:]
  @State private var isApplying = false
  @State private var applyError: String?

  private var allResolved: Bool {
    execution.conflictFiles.allSatisfy { resolutions[$0.filePath] != nil }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Toolbar
      HStack {
        Text("Resolve Merge Conflicts")
          .font(.headline)
        Spacer()
        Text("\(execution.conflictFiles.count) file(s) conflicted")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()

      Divider()

      HSplitView {
        // Left: file list
        fileListColumn
          .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

        // Right: diff viewer
        diffViewerColumn
          .frame(minWidth: 400, maxWidth: .infinity)
      }

      Divider()

      // Bottom toolbar
      HStack {
        if let applyError {
          Label(applyError, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
            .font(.caption)
        }
        Spacer()
        Button("Cancel") {
          Task {
            await runner.abortMerge(in: run)
            dismiss()
          }
        }
        .keyboardShortcut(.cancelAction)

        Button("Apply Resolution") {
          Task {
            isApplying = true
            applyError = nil
            do {
              try await runner.resolveAndMerge(execution, in: run, resolutions: resolutions)
              dismiss()
            } catch {
              applyError = error.localizedDescription
            }
            isApplying = false
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!allResolved || isApplying)
        .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(minWidth: 700, minHeight: 500)
    .task {
      loadFileContents()
      if let first = execution.conflictFiles.first {
        selectedFile = first
      }
    }
  }

  // MARK: - Left column

  private var fileListColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Conflicted Files")
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      Divider()

      ScrollView {
        VStack(spacing: 0) {
          ForEach(execution.conflictFiles) { file in
            conflictFileRow(file)
          }
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private func conflictFileRow(_ file: MergeConflictFile) -> some View {
    let isSelected = selectedFile?.id == file.id
    VStack(alignment: .leading, spacing: 6) {
      Button {
        selectedFile = file
      } label: {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(resolutions[file.filePath] != nil ? .green : .orange)
            .font(.caption)
          Text(file.filePath.split(separator: "/").last.map(String.init) ?? file.filePath)
            .font(.caption.monospaced())
            .lineLimit(1)
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Resolution picker
      Picker("", selection: Binding(
        get: { resolutions[file.filePath] },
        set: { resolutions[file.filePath] = $0 }
      )) {
        Text("Choose…").tag(Optional<ConflictResolution>.none)
        Text("Keep Ours").tag(Optional<ConflictResolution>.some(.ours))
        Text("Keep Theirs").tag(Optional<ConflictResolution>.some(.theirs))
        Text("Use Editor").tag(Optional<ConflictResolution>.some(.editor))
      }
      .pickerStyle(.menu)
      .padding(.horizontal, 12)
      .padding(.bottom, 4)
    }
    .overlay(Divider(), alignment: .bottom)
  }

  // MARK: - Right column

  private var diffViewerColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let file = selectedFile {
        HStack {
          Text(file.filePath)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            Task {
              let absolutePath = run.projectPath + "/" + file.filePath
              try? await VSCodeService.shared.open(path: absolutePath)
              resolutions[file.filePath] = .editor
            }
          } label: {
            Label("Open in Editor", systemImage: "terminal")
          }
          .buttonStyle(.bordered)
          .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Divider()

        let content = fileContents[file.filePath] ?? file.content
        if content.isEmpty {
          ContentUnavailableView(
            "No content",
            systemImage: "doc.text",
            description: Text("File content could not be loaded.")
          )
        } else {
          conflictDiffView(content: content)
        }
      } else {
        ContentUnavailableView(
          "Select a File",
          systemImage: "doc.text",
          description: Text("Choose a conflicted file from the list to view its diff.")
        )
      }
    }
  }

  private func conflictDiffView(content: String) -> some View {
    ScrollView([.horizontal, .vertical]) {
      VStack(alignment: .leading, spacing: 0) {
        let lines = content.components(separatedBy: "\n")
        var oursSection = false
        var theirsSection = false
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          conflictLineView(line: line, oursSection: &oursSection, theirsSection: &theirsSection)
        }
      }
      .padding(8)
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  @ViewBuilder
  private func conflictLineView(line: String, oursSection: inout Bool, theirsSection: inout Bool) -> some View {
    let color = conflictLineBackground(line: line, oursSection: &oursSection, theirsSection: &theirsSection)
    let isMarker = line.hasPrefix("<<<<<<<") || line.hasPrefix("=======") || line.hasPrefix(">>>>>>>")

    Text(line.isEmpty ? " " : line)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(isMarker ? Color.secondary : Color.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(color.map { Color($0) } ?? Color.clear)
  }

  /// Returns the background color for a conflict line and updates section tracking.
  private func conflictLineBackground(
    line: String,
    oursSection: inout Bool,
    theirsSection: inout Bool
  ) -> NSColor? {
    if line.hasPrefix("<<<<<<<") {
      oursSection = true
      theirsSection = false
      return NSColor.systemBlue.withAlphaComponent(0.12)
    } else if line.hasPrefix("=======") {
      oursSection = false
      theirsSection = true
      return nil
    } else if line.hasPrefix(">>>>>>>") {
      theirsSection = false
      return NSColor.systemOrange.withAlphaComponent(0.12)
    } else if oursSection {
      return NSColor.systemBlue.withAlphaComponent(0.08)
    } else if theirsSection {
      return NSColor.systemOrange.withAlphaComponent(0.08)
    }
    return nil
  }

  // MARK: - Helpers

  private func loadFileContents() {
    for file in execution.conflictFiles {
      guard fileContents[file.filePath] == nil else { continue }
      let absolutePath: String
      if file.filePath.hasPrefix("/") {
        absolutePath = file.filePath
      } else {
        absolutePath = run.projectPath + "/" + file.filePath
      }
      if let content = try? String(contentsOfFile: absolutePath, encoding: .utf8) {
        fileContents[file.filePath] = content
      }
    }
  }
}
