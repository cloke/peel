#if canImport(Github)
import Foundation
import Github
import SwiftUI

/// Shared service that fetches open PRs across all tracked repositories.
/// Replaces duplicated `fetchAllOpenPRs()` in `RepositoriesCommandCenter` and `PRReviewQueueDetailView`.
@MainActor
@Observable
class OpenPRsFetcher {
  var fetchedOpenPRs: [(ownerRepo: String, pr: UnifiedRepository.PRSummary)] = []
  var isLoading = false

  func fetch(repositories: [UnifiedRepository]) async {
    isLoading = true
    defer { isLoading = false }

    let repos = repositories.compactMap { repo -> (String, String, String)? in
      guard let ownerRepo = repo.ownerSlashRepo else { return nil }
      let parts = ownerRepo.split(separator: "/")
      guard parts.count == 2 else { return nil }
      return (ownerRepo, String(parts[0]), String(parts[1]))
    }

    var results: [(ownerRepo: String, pr: UnifiedRepository.PRSummary)] = []

    await withTaskGroup(of: [(String, UnifiedRepository.PRSummary)].self) { group in
      for (ownerRepo, owner, repoName) in repos {
        group.addTask {
          do {
            let prs = try await Github.pullRequests(owner: owner, repository: repoName, state: "open")
            return prs.map { pr in
              (ownerRepo, UnifiedRepository.PRSummary(
                id: UUID(),
                number: pr.number,
                title: pr.title ?? "Untitled",
                state: pr.state ?? "open",
                htmlURL: pr.html_url,
                headRef: pr.head.ref,
                updatedAt: pr.updated_at
              ))
            }
          } catch {
            return []
          }
        }
      }

      for await batch in group {
        results.append(contentsOf: batch)
      }
    }

    fetchedOpenPRs = results
  }

  /// Resolve fetched PR tuples to `(repo, pr)` pairs using the aggregator's repositories.
  /// Falls back to aggregator cache when no fetched data is available.
  func resolvedOpenPRs(from repositories: [UnifiedRepository]) -> [(repo: UnifiedRepository, pr: UnifiedRepository.PRSummary)] {
    if !fetchedOpenPRs.isEmpty {
      return fetchedOpenPRs.compactMap { item in
        guard let repo = repositories.first(where: { $0.ownerSlashRepo == item.ownerRepo })
        else { return nil }
        return (repo, item.pr)
      }
    }
    return repositories.flatMap { repo in
      repo.recentPRs.filter { $0.state == "open" }.map { (repo, $0) }
    }
  }
}
#endif
