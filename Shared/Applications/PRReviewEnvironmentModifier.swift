//
//  PRReviewEnvironmentModifier.swift
//  Peel
//
//  Shared ViewModifier that wires up the PR agent-review bridge,
//  status bridge, and review sheet so every surface gets identical
//  behaviour without duplicating the setup code.
//

import SwiftUI
#if canImport(Github)
import Github
#endif

#if canImport(Github)

// MARK: - PR Review Status Bridge

/// Bridges PRReviewQueue to the Github package's PRReviewStatusProvider protocol.
@MainActor
final class PRReviewStatusBridge: PRReviewStatusProvider {
  weak var queue: PRReviewQueue?

  func reviewStatus(owner: String, repo: String, prNumber: Int) -> PRAgentReviewStatus? {
    guard let item = queue?.find(repoOwner: owner, repoName: repo, prNumber: prNumber) else {
      return nil
    }
    let phase = item.phase
    let activePh: Set<String> = [PRReviewPhase.reviewing, PRReviewPhase.fixing, PRReviewPhase.pushing]

    // Build review result if output exists
    var reviewResult: PRAgentReviewStatus.ReviewResult?
    if !item.reviewOutput.isEmpty {
      let parsed = parseReviewOutput(item.reviewOutput)
      reviewResult = PRAgentReviewStatus.ReviewResult(
        summary: parsed.summary,
        verdict: parsed.verdict.rawValue,
        riskLevel: parsed.riskLevel,
        issues: parsed.issues,
        suggestions: parsed.suggestions,
        rawOutput: parsed.rawOutput,
        model: item.reviewModel,
        completedAt: item.reviewCompletedAt
      )
    }

    return PRAgentReviewStatus(
      phase: phase,
      displayName: PRReviewPhase.displayName[phase] ?? phase,
      systemImage: PRReviewPhase.systemImage[phase] ?? "questionmark.circle",
      isActive: activePh.contains(phase),
      reviewResult: reviewResult
    )
  }
}

// MARK: - Shared View Modifier

#if os(macOS)
/// ViewModifier that injects the PR review agent coordinator, status bridge,
/// and review sheet into the environment. Use `.prReviewEnvironment()` on any
/// view that hosts PullRequestDetailView or similar PR surfaces.
struct PRReviewEnvironmentModifier: ViewModifier {
  @Environment(MCPServerService.self) private var mcpServer
  @State private var reviewAgentCoordinator = PRReviewAgentCoordinator()
  @State private var reviewTarget: AgentReviewTarget?
  @State private var reviewStatusBridge = PRReviewStatusBridge()

  /// Optional resolver for mapping a GitHub repo to a local clone path.
  /// When nil the review sheet receives nil for localRepoPath.
  var localRepoResolver: LocalRepoResolver?

  func body(content: Content) -> some View {
    content
      .reviewWithAgentProvider(reviewAgentCoordinator)
      .prReviewStatusProvider(reviewStatusBridge)
      .sheet(item: $reviewTarget) { target in
        AgentReviewSheet(target: target)
      }
      .onAppear {
        reviewStatusBridge.queue = mcpServer.prReviewQueue
        reviewAgentCoordinator.onReview = { pr, repo in
          let localPath = localRepoResolver?.localPath(for: repo)
          reviewTarget = PRReviewAgentCoordinator.makeTarget(pr: pr, repo: repo, localRepoPath: localPath)
        }
      }
  }
}
#endif

// MARK: - View Extension

extension View {
  /// Injects the shared PR review environment (agent coordinator, status bridge,
  /// review sheet) into this view hierarchy.
  ///
  /// - Parameter localRepoResolver: Optional resolver that maps GitHub repos to
  ///   local clone paths. Pass `nil` when no local repo information is available.
  @ViewBuilder
  func prReviewEnvironment(localRepoResolver: LocalRepoResolver? = nil) -> some View {
    #if os(macOS)
    self.modifier(PRReviewEnvironmentModifier(localRepoResolver: localRepoResolver))
    #else
    self.reviewWithAgentProvider(nil)
    #endif
  }
}

#endif
