//
//  PRCommentsView.swift
//  Github
//
//  Shows PR comments (conversation + inline review comments) with auto-polling.
//

import MarkdownUI
import PeelUI
import SwiftUI

struct PRCommentsView: View {
  let owner: String
  let repo: String
  let pullNumber: Int

  /// Polling interval in seconds
  var pollInterval: TimeInterval = 30

  @State private var comments: [CommentItem] = []
  @State private var isLoading = true
  @State private var error: String?
  @State private var lastUpdated: Date?
  @State private var pollTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header
      HStack {
        Text("Comments")
          .font(.headline)

        if !comments.isEmpty {
          Text("\(comments.count)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
        }

        Spacer()

        if let lastUpdated {
          Text("Updated \(timeAgo(lastUpdated))")
            .font(.caption2)
            .foregroundStyle(.quaternary)
        }

        Button {
          Task { await loadComments() }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Refresh comments")
      }

      // Content
      if isLoading && comments.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading comments...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      } else if let error, comments.isEmpty {
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
      } else if comments.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "bubble.left")
            .foregroundStyle(.tertiary)
          Text("No comments yet")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(comments) { comment in
            CommentRow(comment: comment)
            if comment.id != comments.last?.id {
              Divider()
                .padding(.leading, 44)
            }
          }
        }
        .padding(4)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
      }
    }
    .task(id: pullNumber) {
      await loadComments()
      startPolling()
    }
    .onDisappear {
      pollTask?.cancel()
    }
  }

  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(pollInterval))
        guard !Task.isCancelled else { break }
        await loadComments()
      }
    }
  }

  private func loadComments() async {
    if comments.isEmpty { isLoading = true }
    defer { isLoading = false }

    do {
      async let issueTask = Github.issueComments(owner: owner, repository: repo, number: pullNumber)
      async let reviewTask = Github.reviewComments(owner: owner, repository: repo, number: pullNumber)

      let (issueComments, reviewComments) = try await (issueTask, reviewTask)

      var items = [CommentItem]()

      for c in issueComments {
        items.append(CommentItem(
          id: "issue-\(c.id)",
          user: c.user,
          body: c.body,
          createdAt: c.created_at,
          kind: .conversation,
          filePath: nil,
          line: nil,
          diffHunk: nil,
          htmlURL: c.html_url
        ))
      }

      for c in reviewComments {
        items.append(CommentItem(
          id: "review-\(c.id)",
          user: c.user,
          body: c.body,
          createdAt: c.created_at,
          kind: .inline,
          filePath: c.path,
          line: c.line,
          diffHunk: c.diff_hunk,
          htmlURL: c.html_url
        ))
      }

      // Sort chronologically
      items.sort { $0.createdAt < $1.createdAt }
      comments = items
      lastUpdated = Date()
      error = nil
    } catch {
      if comments.isEmpty {
        self.error = "Failed to load: \(error.localizedDescription)"
      }
    }
  }

  private func timeAgo(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    return "\(minutes / 60)h ago"
  }
}

// MARK: - Comment Item

struct CommentItem: Identifiable {
  let id: String
  let user: Github.User
  let body: String
  let createdAt: String
  let kind: Kind
  let filePath: String?
  let line: Int?
  let diffHunk: String?
  let htmlURL: String

  enum Kind {
    case conversation
    case inline
  }
}

// MARK: - Comment Row

private struct CommentRow: View {
  let comment: CommentItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      AvatarView(url: URL(string: comment.user.avatar_url), maxWidth: 24, maxHeight: 24)
        .frame(width: 24, height: 24)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 4) {
        // Header: name + time + kind badge
        HStack(spacing: 6) {
          Text(comment.user.publicName)
            .font(.callout)
            .fontWeight(.medium)

          Text(formatDate(comment.createdAt))
            .font(.caption2)
            .foregroundStyle(.tertiary)

          if comment.kind == .inline {
            HStack(spacing: 3) {
              Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 8))
              if let path = comment.filePath {
                Text((path as NSString).lastPathComponent)
              }
              if let line = comment.line {
                Text("L\(line)")
              }
            }
            .font(.caption2)
            .foregroundStyle(.blue)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.blue.opacity(0.1), in: Capsule())
          }

          Spacer()

          if let url = URL(string: comment.htmlURL) {
            Link(destination: url) {
              Image(systemName: "arrow.up.right.square")
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Open on GitHub")
          }
        }

        // Inline diff context
        if let hunk = comment.diffHunk, comment.kind == .inline {
          let lastLines = hunkLastLines(hunk, count: 3)
          if !lastLines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(lastLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundStyle(hunkLineColor(line))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 1)
                  .background(hunkLineBackground(line))
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.bottom, 2)
          }
        }

        // Body
        if !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Markdown(Document(stringLiteral: comment.body))
            .font(.callout)
            .textSelection(.enabled)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
  }

  private func formatDate(_ dateString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString) else {
      return dateString
    }
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .abbreviated
    return relative.localizedString(for: date, relativeTo: Date())
  }

  private func hunkLastLines(_ hunk: String, count: Int) -> [String] {
    let lines = hunk.components(separatedBy: "\n")
    return Array(lines.suffix(count))
  }

  private func hunkLineColor(_ line: String) -> Color {
    if line.hasPrefix("+") { return .green }
    if line.hasPrefix("-") { return .red }
    return .secondary
  }

  private func hunkLineBackground(_ line: String) -> Color {
    if line.hasPrefix("+") { return .green.opacity(0.08) }
    if line.hasPrefix("-") { return .red.opacity(0.06) }
    return .clear
  }
}
