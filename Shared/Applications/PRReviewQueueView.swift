//
//  PRReviewQueueView.swift
//  Peel
//
//  Activity dashboard section showing the persistent PR review queue.
//  Each row shows the PR, its current phase, and contextual actions.
//

import SwiftUI
import Github

// MARK: - Queue Section (for RepositoriesCommandCenter)

struct PRReviewQueueSection: View {
  @Environment(MCPServerService.self) private var mcpServer
  var onSelectPR: ((String, Int) -> Void)?

  private var queue: PRReviewQueue { mcpServer.prReviewQueue }

  var body: some View {
    let active = queue.activeItems
    let completed = queue.completedItems

    if !active.isEmpty || !completed.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader("PR Reviews")

        if !active.isEmpty {
          LazyVStack(spacing: 1) {
            ForEach(active, id: \.id) { item in
              PRReviewQueueRow(item: item, onSelectPR: onSelectPR)
            }
          }
          #if os(macOS)
          .background(Color(nsColor: .controlBackgroundColor))
          #else
          .background(Color(.systemGroupedBackground))
          #endif
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if !completed.isEmpty {
          DisclosureGroup("Completed (\(completed.count))") {
            LazyVStack(spacing: 1) {
              ForEach(completed.prefix(10), id: \.id) { item in
                PRReviewQueueRow(item: item, onSelectPR: onSelectPR)
              }
            }
            #if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - Queue Row

struct PRReviewQueueRow: View {
  let item: PRReviewQueueItem
  var onSelectPR: ((String, Int) -> Void)?
  @Environment(MCPServerService.self) private var mcpServer

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Main row
      HStack(spacing: 10) {
        phaseIcon
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text(item.prTitle)
            .font(.callout)
            .fontWeight(.medium)
            .lineLimit(1)

          HStack(spacing: 6) {
            Text(verbatim: "\(item.repoOwner)/\(item.repoName) #\(item.prNumber)")
              .font(.caption)
              .foregroundStyle(.secondary)

            phaseBadge
          }
        }

        Spacer()

        // Chain progress indicator
        chainProgressIndicator

        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .onTapGesture {
        let ownerRepo = "\(item.repoOwner)/\(item.repoName)"
        onSelectPR?(ownerRepo, item.prNumber)
      }
    }
  }

  // MARK: - Phase Icon

  @ViewBuilder
  private var phaseIcon: some View {
    let imageName = PRReviewPhase.systemImage[item.phase] ?? "questionmark.circle"
    Image(systemName: imageName)
      .font(.callout)
      .foregroundStyle(phaseColor)
  }

  private var phaseColor: Color {
    switch PRReviewPhase.color[item.phase] ?? "secondary" {
    case "purple": return .purple
    case "blue": return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "red": return .red
    default: return .secondary
    }
  }

  private var phaseBadge: some View {
    Text(PRReviewPhase.displayName[item.phase] ?? item.phase)
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(phaseColor.opacity(0.1)))
      .foregroundStyle(phaseColor)
  }

  // MARK: - Chain Progress

  @ViewBuilder
  private var chainProgressIndicator: some View {
    let activeChainId = item.phase == PRReviewPhase.fixing ? item.fixChainId : item.reviewChainId
    if !activeChainId.isEmpty, let chain = findChain(activeChainId) {
      switch chain.state {
      case .running:
        ProgressView()
          .controlSize(.small)
      case .complete:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.caption)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.red)
          .font(.caption)
      default:
        EmptyView()
      }
    }
  }

  // MARK: - Helpers

  private func findChain(_ chainId: String) -> AgentChain? {
    guard !chainId.isEmpty, let uuid = UUID(uuidString: chainId) else { return nil }
    return mcpServer.agentManager.chains.first { $0.id == uuid }
  }

}

// MARK: - Detail View (for sidebar navigation)

struct PRReviewQueueDetailView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @Environment(RepositoryAggregator.self) private var aggregator

  private var queue: PRReviewQueue { mcpServer.prReviewQueue }

  @State private var prsFetcher = OpenPRsFetcher()
  @State private var selectedPRDetail: PRDetailIdentifier?
  @State private var sortOrder: PRSortOrder = .updatedDesc
  @State private var repoFilter: String = "all"

  enum PRSortOrder: String, CaseIterable {
    case updatedDesc = "Recently Updated"
    case updatedAsc = "Least Recently Updated"
    case newestFirst = "Newest First"
    case oldestFirst = "Oldest First"
    case repoName = "Repository"
  }

  private var availableRepos: [String] {
    let names = Set(allOpenPRsRaw.map { $0.repo.displayName })
    return names.sorted()
  }

  private var allOpenPRsRaw: [(repo: UnifiedRepository, pr: UnifiedRepository.PRSummary)] {
    prsFetcher.resolvedOpenPRs(from: aggregator.repositories)
  }

  private var allOpenPRs: [(repo: UnifiedRepository, pr: UnifiedRepository.PRSummary)] {
    var items = allOpenPRsRaw

    // Apply repo filter
    if repoFilter != "all" {
      items = items.filter { $0.repo.displayName == repoFilter }
    }

    // Apply sort
    items.sort { a, b in
      switch sortOrder {
      case .updatedDesc:
        return (a.pr.updatedAt ?? "") > (b.pr.updatedAt ?? "")
      case .updatedAsc:
        return (a.pr.updatedAt ?? "") < (b.pr.updatedAt ?? "")
      case .newestFirst:
        return a.pr.number > b.pr.number
      case .oldestFirst:
        return a.pr.number < b.pr.number
      case .repoName:
        if a.repo.displayName != b.repo.displayName {
          return a.repo.displayName < b.repo.displayName
        }
        return a.pr.number > b.pr.number
      }
    }
    return items
  }

  var body: some View {
    Group {
      if let detail = selectedPRDetail {
        PRDetailInlineView(ownerRepo: detail.ownerRepo, prNumber: detail.prNumber) {
          selectedPRDetail = nil
        }
      } else {
        mainContent
      }
    }
    .navigationTitle("PR Reviews")
  }

  private var mainContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // MCP review queue
        PRReviewQueueSection(onSelectPR: { ownerRepo, prNumber in
          selectedPRDetail = PRDetailIdentifier(ownerRepo: ownerRepo, prNumber: prNumber)
        })

        // Open PRs from tracked repos
        openPRsSection

        if queue.activeItems.isEmpty && queue.completedItems.isEmpty && allOpenPRs.isEmpty && !prsFetcher.isLoading {
          ContentUnavailableView {
            Label("No Pull Requests", systemImage: "arrow.triangle.pull")
          } description: {
            Text("Open PRs from your tracked repositories will appear here.\nEnqueue PRs for automated review via MCP or the template browser.")
          }
        }
      }
      .padding(20)
    }
    .task { await prsFetcher.fetch(repositories: aggregator.repositories) }
  }

  @ViewBuilder
  private var openPRsSection: some View {
    if prsFetcher.isLoading && allOpenPRs.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Open Pull Requests")
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading open PRs…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
      }
    } else if !allOpenPRsRaw.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        // Header with sort & filter controls
        HStack {
          SectionHeader("Open Pull Requests (\(allOpenPRs.count))")
          Spacer()

          if availableRepos.count > 1 {
            Menu {
              Button { repoFilter = "all" } label: {
                HStack {
                  Text("All Repos")
                  if repoFilter == "all" { Image(systemName: "checkmark") }
                }
              }
              Divider()
              ForEach(availableRepos, id: \.self) { repo in
                Button { repoFilter = repo } label: {
                  HStack {
                    Text(repo)
                    if repoFilter == repo { Image(systemName: "checkmark") }
                  }
                }
              }
            } label: {
              Label(repoFilter == "all" ? "All Repos" : repoFilter, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(repoFilter == "all" ? Color.secondary : Color.blue)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
          }

          Menu {
            ForEach(PRSortOrder.allCases, id: \.self) { order in
              Button { sortOrder = order } label: {
                HStack {
                  Text(order.rawValue)
                  if sortOrder == order { Image(systemName: "checkmark") }
                }
              }
            }
          } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }

        if allOpenPRs.isEmpty {
          Text("No PRs matching filter")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        } else {
          LazyVStack(spacing: 1) {
            ForEach(allOpenPRs, id: \.pr.id) { item in
              openPRRow(item)
            }
          }
          #if os(macOS)
          .background(Color(nsColor: .controlBackgroundColor))
          #else
          .background(Color(.systemGroupedBackground))
          #endif
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  private func openPRRow(_ item: (repo: UnifiedRepository, pr: UnifiedRepository.PRSummary)) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "arrow.triangle.pull")
        .font(.callout)
        .foregroundStyle(.green)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: "#\(item.pr.number) \(item.pr.title)")
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(item.repo.displayName)
            .font(.caption)
            .foregroundStyle(.blue)
          if let ref = item.pr.headRef {
            Text("· \(ref)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }

      Spacer()

      if let updatedAt = item.pr.updatedAt,
         let date = ISO8601DateFormatter().date(from: updatedAt) {
        Text(date, style: .relative)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Text("Open")
        .font(.caption2)
        .fontWeight(.bold)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.green.opacity(0.15)))
        .foregroundStyle(.green)

      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      if let ownerRepo = item.repo.ownerSlashRepo {
        selectedPRDetail = PRDetailIdentifier(ownerRepo: ownerRepo, prNumber: item.pr.number)
      }
    }
  }

}

