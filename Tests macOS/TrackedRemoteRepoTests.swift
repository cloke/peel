import XCTest
import SwiftData
import Foundation
@testable import Peel

@MainActor
final class TrackedRemoteRepoTests: XCTestCase {

  var modelContainer: ModelContainer!
  var dataService: DataService!

  override func setUp() async throws {
    let schema = Schema([
      TrackedRemoteRepo.self,
      TrackedRepoDeviceState.self,
      // DataService may touch these during init
      MCPRunRecord.self,
      DeviceSettings.self
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    modelContainer = try ModelContainer(for: schema, configurations: config)
    dataService = DataService(modelContext: modelContainer.mainContext)
  }

  override func tearDown() async throws {
    modelContainer = nil
    dataService = nil
  }

  // MARK: - Model Tests

  func testTrackedRemoteRepoDefaults() {
    let repo = TrackedRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo"
    )
    XCTAssertEqual(repo.branch, "main")
    XCTAssertEqual(repo.remoteName, "origin")
    XCTAssertEqual(repo.pullIntervalSeconds, 3600)
    XCTAssertTrue(repo.isEnabled)
    XCTAssertTrue(repo.reindexAfterPull)
  }

  func testDeviceStateIsPullDue_neverPulled() {
    let state = TrackedRepoDeviceState(trackedRepoId: UUID(), localPath: "/tmp/repo")
    XCTAssertTrue(state.isPullDue(interval: 3600), "State that has never been pulled should be due")
  }

  func testDeviceStateIsPullDue_recentlyPulled() {
    let state = TrackedRepoDeviceState(trackedRepoId: UUID(), localPath: "/tmp/repo")
    state.lastPullAt = Date()
    XCTAssertFalse(state.isPullDue(interval: 3600), "State pulled just now should not be due")
  }

  func testDeviceStateIsPullDue_overdue() {
    let state = TrackedRepoDeviceState(trackedRepoId: UUID(), localPath: "/tmp/repo")
    state.lastPullAt = Date(timeIntervalSinceNow: -7200) // 2 hours ago
    XCTAssertTrue(state.isPullDue(interval: 3600), "State pulled 2h ago with 1h interval should be due")
  }

  func testTouch() {
    let repo = TrackedRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo"
    )
    let before = repo.modifiedAt
    // Small delay to ensure time difference
    Thread.sleep(forTimeInterval: 0.01)
    repo.touch()
    XCTAssertGreaterThan(repo.modifiedAt, before)
  }

  // MARK: - DataService CRUD Tests

  func testTrackRemoteRepo_create() {
    let repo = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/Users/test/code/repo"
    )

    XCTAssertEqual(repo.remoteURL, "https://github.com/org/repo.git")
    XCTAssertEqual(repo.name, "repo")

    // Verify device state was created with localPath
    let state = dataService.getDeviceState(for: repo)
    XCTAssertNotNil(state)
    XCTAssertEqual(state?.localPath, "/Users/test/code/repo")

    let all = dataService.getTrackedRemoteRepos()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all.first?.remoteURL, "https://github.com/org/repo.git")
  }

  func testTrackRemoteRepo_upsert() {
    // Create initial tracking
    _ = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/Users/test/code/repo",
      branch: "main"
    )

    // Update with same URL but different settings
    let updated = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/Users/test/code/repo-v2",
      branch: "develop"
    )

    let state = dataService.getDeviceState(for: updated)
    XCTAssertEqual(state?.localPath, "/Users/test/code/repo-v2")
    XCTAssertEqual(updated.branch, "develop")

    // Should still be just one record
    let all = dataService.getTrackedRemoteRepos()
    XCTAssertEqual(all.count, 1)
  }

  func testTrackRemoteRepo_customSettings() {
    let repo = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "custom-repo",
      localPath: "/Users/test/code/repo",
      branch: "develop",
      remoteName: "upstream",
      pullIntervalSeconds: 1800,
      reindexAfterPull: false
    )

    XCTAssertEqual(repo.branch, "develop")
    XCTAssertEqual(repo.remoteName, "upstream")
    XCTAssertEqual(repo.pullIntervalSeconds, 1800)
    XCTAssertFalse(repo.reindexAfterPull)

    let state = dataService.getDeviceState(for: repo)
    XCTAssertEqual(state?.localPath, "/Users/test/code/repo")
  }

  func testGetTrackedRemoteRepo_byURL() {
    _ = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/tmp/repo"
    )

    let found = dataService.getTrackedRemoteRepo(remoteURL: "https://github.com/org/repo.git")
    XCTAssertNotNil(found)
    XCTAssertEqual(found?.name, "repo")
  }

  func testGetTrackedRemoteRepo_byId() {
    let created = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/tmp/repo"
    )

    let found = dataService.getTrackedRemoteRepo(id: created.id)
    XCTAssertNotNil(found)
    XCTAssertEqual(found?.name, "repo")
  }

  func testUntrackRemoteRepo_byURL() {
    let repo = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/tmp/repo"
    )

    // Verify device state exists before untracking
    XCTAssertNotNil(dataService.getDeviceState(for: repo))

    let result = dataService.untrackRemoteRepo(remoteURL: "https://github.com/org/repo.git")
    XCTAssertTrue(result)

    let all = dataService.getTrackedRemoteRepos()
    XCTAssertEqual(all.count, 0)
  }

  func testUntrackRemoteRepo_byId() {
    let created = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/tmp/repo"
    )

    // Verify device state exists before untracking
    XCTAssertNotNil(dataService.getDeviceState(for: created))

    let result = dataService.untrackRemoteRepo(id: created.id)
    XCTAssertTrue(result)

    let all = dataService.getTrackedRemoteRepos()
    XCTAssertEqual(all.count, 0)
  }

  func testUntrackRemoteRepo_notFound() {
    let result = dataService.untrackRemoteRepo(remoteURL: "https://github.com/org/nonexistent.git")
    XCTAssertFalse(result)
  }

  func testGetDueTrackedRepos() {
    // Create repo that's due (never pulled)
    _ = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/due-repo.git",
      name: "due-repo",
      localPath: "/tmp/due-repo"
    )

    // Create repo that's not due (just pulled)
    let notDueRepo = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/fresh-repo.git",
      name: "fresh-repo",
      localPath: "/tmp/fresh-repo"
    )
    let notDueState = dataService.getDeviceState(for: notDueRepo)
    notDueState?.lastPullAt = Date()
    try? modelContainer.mainContext.save()

    // Create disabled repo
    let disabled = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/disabled-repo.git",
      name: "disabled-repo",
      localPath: "/tmp/disabled-repo"
    )
    disabled.isEnabled = false
    try? modelContainer.mainContext.save()

    let due = dataService.getDueTrackedRepos()
    XCTAssertEqual(due.count, 1)
    XCTAssertEqual(due.first?.0.name, "due-repo")
  }

  func testUpdateTrackedRepoPullResult_success() {
    let repo = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/tmp/repo"
    )

    let state = dataService.getOrCreateDeviceState(for: repo)
    dataService.updateTrackedRepoPullResult(state, result: "updated to abc123", error: nil)

    XCTAssertNotNil(state.lastPullAt)
    XCTAssertEqual(state.lastPullResult, "updated to abc123")
    XCTAssertNil(state.lastPullError)
  }

  func testUpdateTrackedRepoPullResult_error() {
    let repo = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/repo.git",
      name: "repo",
      localPath: "/tmp/repo"
    )

    let state = dataService.getOrCreateDeviceState(for: repo)
    dataService.updateTrackedRepoPullResult(state, result: nil, error: "git fetch failed: timeout")

    XCTAssertNotNil(state.lastPullAt)
    XCTAssertNil(state.lastPullResult)
    XCTAssertEqual(state.lastPullError, "git fetch failed: timeout")
  }

  func testMultipleTrackedRepos() {
    _ = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/alpha.git",
      name: "alpha",
      localPath: "/Users/test/alpha"
    )
    _ = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/beta.git",
      name: "beta",
      localPath: "/Users/test/beta"
    )
    _ = dataService.trackRemoteRepo(
      remoteURL: "https://github.com/org/gamma.git",
      name: "gamma",
      localPath: "/Users/test/gamma"
    )

    let all = dataService.getTrackedRemoteRepos()
    XCTAssertEqual(all.count, 3)

    // Should be sorted by name
    XCTAssertEqual(all[0].name, "alpha")
    XCTAssertEqual(all[1].name, "beta")
    XCTAssertEqual(all[2].name, "gamma")
  }

  // MARK: - RepoPullResult Tests

  func testRepoPullResult_descriptions() {
    XCTAssertEqual(RepoPullResult.upToDate.description, "up-to-date")
    XCTAssertEqual(RepoPullResult.updated("abc123").description, "updated to abc123")
    XCTAssertEqual(RepoPullResult.error("fail").description, "error: fail")
  }

  func testRepoPullResult_isError() {
    XCTAssertFalse(RepoPullResult.upToDate.isError)
    XCTAssertFalse(RepoPullResult.updated("abc").isError)
    XCTAssertTrue(RepoPullResult.error("fail").isError)
  }

  // MARK: - PullHistoryEntry Tests

  func testPullHistoryEntry() {
    let entry = PullHistoryEntry(
      repoName: "test-repo",
      remoteURL: "https://github.com/org/repo.git",
      localPath: "/tmp/repo",
      result: "updated to abc123",
      success: true
    )

    XCTAssertEqual(entry.repoName, "test-repo")
    XCTAssertEqual(entry.remoteURL, "https://github.com/org/repo.git")
    XCTAssertTrue(entry.success)
    XCTAssertNotNil(entry.id)
    XCTAssertNotNil(entry.timestamp)
  }
}
