//
//  AppResetService.swift
//  Peel
//
//  Performs a complete app reset — clears all persisted data to simulate a fresh install.
//

import Foundation
import Github
import OSLog
import SwiftData

@MainActor
enum AppResetService {
  private static let logger = Logger(subsystem: "com.peel.services", category: "AppReset")

  /// Performs a full reset of all app data stores, then terminates the app.
  /// - Parameter modelContext: The active SwiftData model context.
  static func resetAll(modelContext: ModelContext) async {
    logger.warning("Beginning full app reset")

    // 1. SwiftData — delete all objects from both synced and device-local stores
    deleteAllSwiftData(modelContext: modelContext)

    // 2. Keychain — remove GitHub OAuth token via the public API
    await clearKeychain()

    // 3. RAG database — delete SQLite files
    clearRAGDatabase()

    // 4. Scratch directories
    clearScratchDirectories()

    // 5. Screenshots directory
    clearScreenshots()

    // 6. UserDefaults — nuke the whole domain
    clearUserDefaults()

    // 7. Firebase — sign out
    clearFirebase()

    logger.warning("Full app reset complete — terminating")

    // Terminate so the app launches fresh
    #if os(macOS)
    NSApplication.shared.terminate(nil)
    #else
    exit(0)
    #endif
  }

  // MARK: - SwiftData

  private static func deleteAllSwiftData(modelContext: ModelContext) {
    let modelTypes: [any PersistentModel.Type] = [
      SyncedRepository.self,
      GitHubFavorite.self,
      RecentPullRequest.self,
      TrackedRemoteRepo.self,
      LocalRepositoryPath.self,
      TrackedWorktree.self,
      SwarmBranchReservation.self,
      PRQueueOperationRecord.self,
      PRQueueCreatedPRRecord.self,
      DeviceSettings.self,
      MCPRunRecord.self,
      MCPRunResultRecord.self,
      ParallelRunSnapshot.self,
      RepoGuidanceSkill.self,
      CIFailureRecord.self,
      FeatureDiscoveryChecklist.self,
      PRReviewQueueItem.self,
      TrackedRepoDeviceState.self,
    ]

    for type in modelTypes {
      do {
        try modelContext.delete(model: type)
        logger.info("Deleted all \(String(describing: type))")
      } catch {
        logger.error("Failed to delete \(String(describing: type)): \(error)")
      }
    }

    do {
      try modelContext.save()
      logger.info("SwiftData changes saved")
    } catch {
      logger.error("Failed to save SwiftData deletions: \(error)")
    }
  }

  // MARK: - Keychain

  private static func clearKeychain() async {
    await Github.reauthorize()
    logger.info("Cleared GitHub OAuth token from keychain")
  }

  // MARK: - RAG Database

  private static func clearRAGDatabase() {
    let ragURL = LocalRAGArtifacts.ragBaseURL()
    let fm = FileManager.default
    if fm.fileExists(atPath: ragURL.path) {
      do {
        try fm.removeItem(at: ragURL)
        logger.info("Removed RAG database directory")
      } catch {
        logger.error("Failed to remove RAG directory: \(error)")
      }
    }
  }

  // MARK: - Scratch

  private static func clearScratchDirectories() {
    do {
      try ScratchAreaService.deleteAllScratchDirectories()
      logger.info("Cleared scratch directories")
    } catch {
      logger.error("Failed to clear scratch directories: \(error)")
    }
  }

  // MARK: - Screenshots

  private static func clearScreenshots() {
    let fm = FileManager.default
    guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return
    }
    let screenshotsDir = appSupport
      .appendingPathComponent("Peel", isDirectory: true)
      .appendingPathComponent("Screenshots", isDirectory: true)
    if fm.fileExists(atPath: screenshotsDir.path) {
      do {
        try fm.removeItem(at: screenshotsDir)
        logger.info("Removed screenshots directory")
      } catch {
        logger.error("Failed to remove screenshots: \(error)")
      }
    }
  }

  // MARK: - UserDefaults

  private static func clearUserDefaults() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    UserDefaults.standard.removePersistentDomain(forName: bundleID)
    UserDefaults.standard.synchronize()
    logger.info("Cleared UserDefaults for \(bundleID)")
  }

  // MARK: - Firebase

  private static func clearFirebase() {
    do {
      try FirebaseService.shared.signOut()
      logger.info("Signed out of Firebase")
    } catch {
      logger.error("Failed to sign out of Firebase: \(error)")
    }
  }
}
