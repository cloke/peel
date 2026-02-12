//
//  PeonPingService.swift
//  Peel
//
//  Peon-ping style sound notifications for agent and worktree events.
//  Inspired by https://github.com/tonyyont/peon-ping
//
//  Sound files are property of Blizzard Entertainment.
//

#if os(macOS)
import AppKit
#endif
import AVFoundation
import Foundation
import Observation
import OSLog
import UserNotifications

// MARK: - Sound Event Categories

/// Maps agent/worktree lifecycle events to peon-ping sound categories.
enum PeonSoundCategory: String, CaseIterable, Codable, Sendable {
  case greeting    // Chain/run starts
  case acknowledge // Agent picks up a task
  case complete    // Chain/run finished successfully
  case error       // Chain/run failed
  case permission  // Needs user review/approval
}

// MARK: - Sound Pack Manifest

struct SoundEntry: Codable, Sendable {
  let file: String
  let line: String
}

struct SoundCategory: Codable, Sendable {
  let sounds: [SoundEntry]
}

struct SoundPackManifest: Codable, Sendable {
  let name: String
  let display_name: String
  let attribution: String?
  let categories: [String: SoundCategory]
}

// MARK: - Peon Ping Service

@MainActor
@Observable
final class PeonPingService {
  /// Shared instance for use in non-view contexts (chain runner, worktree runner).
  static let shared = PeonPingService()

  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.peel",
    category: "PeonPing"
  )

  // MARK: - Settings (persisted via @AppStorage in views, read here)

  var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: "peonPing.enabled")
  }

  var volume: Float {
    let vol = UserDefaults.standard.float(forKey: "peonPing.volume")
    return vol > 0 ? vol : 0.5
  }

  var desktopNotificationsEnabled: Bool {
    UserDefaults.standard.bool(forKey: "peonPing.desktopNotifications")
  }

  // Per-category toggles
  func isCategoryEnabled(_ category: PeonSoundCategory) -> Bool {
    let key = "peonPing.category.\(category.rawValue)"
    // Default to true if never set
    if UserDefaults.standard.object(forKey: key) == nil { return true }
    return UserDefaults.standard.bool(forKey: key)
  }

  // MARK: - State

  private var manifest: SoundPackManifest?
  private var lastPlayed: [String: String] = [:] // category -> last file played
  private var audioPlayer: AVAudioPlayer?
  private var notificationRequested = false

  // MARK: - Init

  init() {
    loadManifest()
    requestNotificationPermission()
  }

  // MARK: - Public API

  /// Play when a chain or parallel run starts.
  func chainStarted(name: String) {
    play(.greeting)
    sendNotification(title: "Chain Started", body: "\(name) — Ready to work?")
  }

  /// Play when an individual agent picks up a task.
  func agentStarted(name: String) {
    play(.acknowledge)
  }

  /// Play when a chain or parallel run completes successfully.
  func chainCompleted(name: String) {
    play(.complete)
    sendNotification(title: "Chain Complete", body: "\(name) — Job's done!")
  }

  /// Play when a chain or parallel run fails.
  func chainFailed(name: String, error: String) {
    play(.error)
    sendNotification(title: "Chain Failed", body: "\(name) — \(error)")
  }

  /// Play when a task needs user review/approval.
  func needsReview(name: String) {
    play(.permission)
    sendNotification(title: "Needs Review", body: "\(name) — Something need doing?")
  }

  /// Play when a worktree execution completes.
  func worktreeCompleted(taskTitle: String) {
    play(.complete)
    sendNotification(title: "Worktree Done", body: "\(taskTitle) — Work, work.")
  }

  /// Play when a worktree execution fails.
  func worktreeFailed(taskTitle: String, error: String) {
    play(.error)
    sendNotification(title: "Worktree Failed", body: "\(taskTitle) — \(error)")
  }

  /// Play when a worktree needs review.
  func worktreeNeedsReview(taskTitle: String) {
    play(.permission)
    sendNotification(title: "Worktree Review", body: "\(taskTitle) — Something need doing?")
  }

  // MARK: - Sound Playback

  private func play(_ category: PeonSoundCategory) {
    guard isEnabled, isCategoryEnabled(category) else { return }
    guard let manifest else {
      Self.logger.warning("No sound pack manifest loaded")
      return
    }

    guard let soundCategory = manifest.categories[category.rawValue],
          !soundCategory.sounds.isEmpty else {
      Self.logger.debug("No sounds for category: \(category.rawValue)")
      return
    }

    // Pick a random sound, avoiding immediate repeats
    let sounds = soundCategory.sounds
    let lastFile = lastPlayed[category.rawValue]
    let candidates: [SoundEntry]
    if sounds.count > 1 {
      candidates = sounds.filter { $0.file != lastFile }
    } else {
      candidates = sounds
    }

    guard let pick = candidates.randomElement() else { return }
    lastPlayed[category.rawValue] = pick.file

    // Find the sound file in the bundle
    let soundName = (pick.file as NSString).deletingPathExtension
    guard let url = Bundle.main.url(
      forResource: soundName,
      withExtension: (pick.file as NSString).pathExtension,
      subdirectory: "Sounds/peon"
    ) else {
      Self.logger.warning("Sound file not found in bundle: \(pick.file)")
      return
    }

    do {
      audioPlayer = try AVAudioPlayer(contentsOf: url)
      audioPlayer?.volume = volume
      audioPlayer?.play()
      Self.logger.debug("Playing \(category.rawValue): \(pick.line)")
    } catch {
      Self.logger.error("Failed to play sound: \(error.localizedDescription)")
    }
  }

  // MARK: - Manifest Loading

  private func loadManifest() {
    guard let url = Bundle.main.url(
      forResource: "manifest",
      withExtension: "json",
      subdirectory: "Sounds/peon"
    ) else {
      Self.logger.warning("Sound pack manifest not found in bundle")
      return
    }

    do {
      let data = try Data(contentsOf: url)
      manifest = try JSONDecoder().decode(SoundPackManifest.self, from: data)
      Self.logger.info("Loaded sound pack: \(self.manifest?.display_name ?? "unknown")")
    } catch {
      Self.logger.error("Failed to load manifest: \(error.localizedDescription)")
    }
  }

  // MARK: - Desktop Notifications

  private func requestNotificationPermission() {
    guard !notificationRequested else { return }
    notificationRequested = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
      if let error {
        Self.logger.warning("Notification permission error: \(error.localizedDescription)")
      } else {
        Self.logger.debug("Notification permission granted: \(granted)")
      }
    }
  }

  private func sendNotification(title: String, body: String) {
    guard desktopNotificationsEnabled else { return }
    #if os(macOS)
    guard !NSApp.isActive else { return } // Only notify when app is in background
    #endif

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = nil // We play our own sound

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        Self.logger.warning("Failed to send notification: \(error.localizedDescription)")
      }
    }
  }
}
