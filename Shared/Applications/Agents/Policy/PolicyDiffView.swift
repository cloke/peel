//
//  PolicyDiffView.swift
//  Peel
//

import SwiftUI

#if os(macOS)
import AppKit

struct PolicyDiffView: View {
  let docA: PolicyDocument
  let docB: PolicyDocument

  @State private var diffLines: [DiffLine] = []
  @State private var isLoading = true

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(docA.title.isEmpty ? "Document A" : docA.title)
            .fontWeight(.semibold)
          Text(docA.importedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

        Divider()

        VStack(alignment: .leading, spacing: 2) {
          Text(docB.title.isEmpty ? "Document B" : docB.title)
            .fontWeight(.semibold)
          Text(docB.importedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .background(.background.secondary)

      Divider()

      if isLoading {
        ProgressView("Computing diff…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if diffLines.isEmpty {
        Text("No differences found.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines) { line in
              HStack(spacing: 0) {
                Text(line.prefix)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(line.prefixColor)
                  .frame(width: 16, alignment: .leading)
                Text(line.content)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(line.textColor)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 1)
              .background(line.background)
            }
          }
        }
      }
    }
    .frame(minWidth: 700, minHeight: 500)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Export Diff") {
          exportDiff()
        }
        .disabled(diffLines.isEmpty)
      }
    }
    .task {
      computeDiff()
    }
  }

  private func computeDiff() {
    isLoading = true
    let linesA = (try? String(contentsOfFile: docA.markdownPath, encoding: .utf8))?
      .components(separatedBy: "\n") ?? []
    let linesB = (try? String(contentsOfFile: docB.markdownPath, encoding: .utf8))?
      .components(separatedBy: "\n") ?? []

    let diff = linesB.difference(from: linesA)

    var result: [DiffLine] = []

    // Build a simple unified-style diff
    var aIdx = 0
    var bIdx = 0
    var changeSet = Set<Int>()
    var insertSet = Set<Int>()
    for change in diff {
      switch change {
      case .remove(let offset, _, _): changeSet.insert(offset)
      case .insert(let offset, _, _): insertSet.insert(offset)
      }
    }

    while aIdx < linesA.count || bIdx < linesB.count {
      let removedInA = aIdx < linesA.count && changeSet.contains(aIdx)
      let insertedInB = bIdx < linesB.count && insertSet.contains(bIdx)

      if removedInA {
        result.append(DiffLine(prefix: "-", content: linesA[aIdx], kind: .removed))
        aIdx += 1
      } else if insertedInB {
        result.append(DiffLine(prefix: "+", content: linesB[bIdx], kind: .inserted))
        bIdx += 1
      } else {
        let content = aIdx < linesA.count ? linesA[aIdx] : (bIdx < linesB.count ? linesB[bIdx] : "")
        result.append(DiffLine(prefix: " ", content: content, kind: .unchanged))
        aIdx += 1
        bIdx += 1
      }
    }

    diffLines = result
    isLoading = false
  }

  private func exportDiff() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "policy-diff.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let header = """
    --- \(docA.title) (\(docA.importedAt.formatted()))
    +++ \(docB.title) (\(docB.importedAt.formatted()))

    """
    let body = diffLines.map { "\($0.prefix) \($0.content)" }.joined(separator: "\n")
    let output = header + body
    try? output.write(to: url, atomically: true, encoding: .utf8)
    NSWorkspace.shared.open(url)
  }
}

private struct DiffLine: Identifiable {
  let id = UUID()
  let prefix: String
  let content: String
  let kind: Kind

  enum Kind { case inserted, removed, unchanged }

  var prefixColor: Color {
    switch kind {
    case .inserted: return .green
    case .removed: return .red
    case .unchanged: return .secondary
    }
  }

  var textColor: Color {
    switch kind {
    case .inserted: return .green
    case .removed: return .red
    case .unchanged: return .primary
    }
  }

  var background: Color {
    switch kind {
    case .inserted: return .green.opacity(0.08)
    case .removed: return .red.opacity(0.08)
    case .unchanged: return .clear
    }
  }
}
#endif
