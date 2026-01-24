//
//  Git_DiffView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

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

  var body: some View {
    Text(text)
      .font(.caption.monospaced())
      .foregroundStyle(.secondary)
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
      Spacer(minLength: 0)
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
  private let logger = Logger(subsystem: "Peel", category: "Git.DiffRender")
  @State private var expandedFiles: Set<UUID> = []
  
  public init(diff: Diff) {
    self.diff = diff
  }
  
  public var body: some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          Spacer(minLength: 4)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)

              if isExpanded.wrappedValue {
                ForEach(file.chunks) { chunk in
                  ChunkHeaderView(text: chunk.chunk)
                  ForEach(chunk.lines) { line in
                    DiffLineRow(line: line, showLineNumbers: line.lineNumber != 0)
                      .background(lineColor(line.status))
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
          }
        }
        .textSelection(.enabled)
        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
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
