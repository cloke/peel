//
//  PeelApp.swift
//  Shared
//
//  Created by Cory Loken on 12/19/20.
//  Updated for SwiftData on 1/7/26
//

import Foundation
import SwiftUI
import SwiftData
import OAuthSwift
import AppKit
import OSLog
import Git
import Github
#if os(macOS)
import ServiceManagement
#endif

// MARK: - Notification Names

extension Notification.Name {
  static let openCommandPalette = Notification.Name("openCommandPalette")
  static let navigateToTool = Notification.Name("navigateToTool")
  static let navigateToSwarmConsole = Notification.Name("navigateToSwarmConsole")
}

// MARK: - App Delegate (macOS)

#if os(macOS)
/// Handles app lifecycle events for daemon mode. When "Run in Background" is enabled,
/// closing the last window enters background mode instead of quitting the app.
final class PeelAppDelegate: NSObject, NSApplicationDelegate {
  var daemonModeService: DaemonModeService?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return daemonModeService?.shouldTerminateAfterLastWindowClosed() ?? true
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let service = daemonModeService, service.isBackgroundMode {
      service.bringToForeground()
    }
    // Return true so Cocoa's default behavior creates a new window if none exist
    return true
  }
}
#endif

@main
struct PeelApp: App {
  #if os(macOS)
  @NSApplicationDelegateAdaptor(PeelAppDelegate.self) var appDelegate
  #endif
  @Environment(\.openURL) var openURL
  @State private var vmIsolationService = VMIsolationService()
  @State private var mcpServer: MCPServerService
  @State private var dataService: DataService
  @State private var repositoryAggregator = RepositoryAggregator()
  @State private var activityFeed = ActivityFeed()
  @State private var workerModeActive = false
  @State private var skillUpdateAvailable = false
  #if os(macOS)
  @State private var daemonModeService = DaemonModeService()
  #endif

  private static var isRunningTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  init() {
    // Start main-thread watchdog early to catch stalls during init
    #if DEBUG
    MainThreadWatchdog.shared.start()
    #endif

    // Configure Firebase first (before other services)
    FirebaseService.shared.configure()
    
    let vmService = VMIsolationService()
    _vmIsolationService = State(initialValue: vmService)
    let mcpServerInstance = MCPServerService(vmIsolationService: vmService)
    _mcpServer = State(initialValue: mcpServerInstance)
    
    // Create DataService with model context and seed default skills
    let container = Self.sharedModelContainer
    let context = ModelContext(container)
    let dataService = DataService(modelContext: context)
    _dataService = State(initialValue: dataService)
    DefaultSkillsService.seedDefaultSkills(context: context)  // Issue #90
    Task { @MainActor in
      dataService.normalizeCommunitySkills()
    }
    // Wire SwiftData context into swarm coordinator for worktree persistence (#282)
    SwarmCoordinator.shared.modelContext = context

    // Eagerly configure MCP server with model context so PRReviewQueue (and other
    // SwiftData-backed services) have persistence from launch — not only after the
    // user navigates to the Agents or Workspaces tab.
    mcpServerInstance.configure(modelContext: context)

    // Wire daemon mode service into MCP server for tool access
    #if os(macOS)
    mcpServerInstance.daemonModeService = _daemonModeService.wrappedValue
    #endif

    // Wire RepoPullScheduler with DataService so tracked repos auto-pull
    RepoPullScheduler.shared.dataService = dataService

    // Wire RepositoryAggregator dependencies
    _repositoryAggregator.wrappedValue.dataService = dataService
    _repositoryAggregator.wrappedValue.mcpServerService = mcpServerInstance
    _repositoryAggregator.wrappedValue.agentManager = mcpServerInstance.agentManager
    _repositoryAggregator.wrappedValue.pullScheduler = RepoPullScheduler.shared

    // Wire ActivityFeed dependencies
    _activityFeed.wrappedValue.dataService = dataService
    _activityFeed.wrappedValue.agentManager = mcpServerInstance.agentManager
    _activityFeed.wrappedValue.pullScheduler = RepoPullScheduler.shared

    // Auto-start swarm on launch when device setting enables it (defaults to true for new installs)
    if !Self.isRunningTests {
      Task { @MainActor in
        let settings = dataService.getDeviceSettings()

        // Migrate stale "worker" role to "hybrid" — worker-only was never the intended default
        // and earlier manual starts may have persisted it.
        if settings.swarmRole == "worker" {
          settings.swarmRole = "hybrid"
          try? context.save()
        }

        // Respect explicit worker-mode flag
        if settings.swarmAutoStart && !WorkerMode.shared.shouldRunInWorkerMode {
          let role = SwarmRole(rawValue: settings.swarmRole) ?? .hybrid
          do {
            try SwarmCoordinator.shared.start(role: role, port: 8766)

            // If signed into Firebase, register worker and start listeners so WAN peers are visible.
            // Firebase auth state is restored asynchronously — wait for it before checking isSignedIn.
            let firebaseService = FirebaseService.shared
            if !firebaseService.isSignedIn {
              for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if firebaseService.isSignedIn { break }
              }
            }

            if firebaseService.isSignedIn {
              let wanAddress = await WANAddressResolver.resolve()
              SwarmCoordinator.shared.setResolvedWANAddress(wanAddress)

              // memberSwarms is populated asynchronously by the auth listener — wait for it.
              var swarms = firebaseService.memberSwarms
              if swarms.isEmpty {
                for _ in 0..<20 {
                  try? await Task.sleep(for: .milliseconds(500))
                  swarms = firebaseService.memberSwarms
                  if !swarms.isEmpty { break }
                }
              }

              let capabilities = WorkerCapabilities.current(
                wanAddress: wanAddress,
                wanPort: 8766
              )
              for swarm in swarms where swarm.role.canRegisterWorkers {
                _ = try? await firebaseService.registerWorker(swarmId: swarm.id, capabilities: capabilities)
                firebaseService.startWorkerListener(swarmId: swarm.id)
                firebaseService.startMessageListener(swarmId: swarm.id)
              }
              if swarms.isEmpty {
                print("Warning: No swarm memberships loaded after 10s — Firestore listeners not started")
              }

              // Reinitialize WebRTC responder and relay provider now that Firebase is
              // signed in and memberSwarms are loaded (they were skipped in start()).
              SwarmCoordinator.shared.reinitializeFirestoreServices()
            } else {
              print("Warning: Firebase auth not restored after 10s — Firestore listeners not started")
            }
          } catch {
            print("Failed to auto-start swarm: \(error)")
          }
        }
      }
    }
    
    // Start the tracked-repo pull scheduler (auto-pulls primary repos hourly)
    if !Self.isRunningTests {
      Task { @MainActor in
        RepoPullScheduler.shared.delegate = mcpServerInstance
        RepoPullScheduler.shared.start()
      }
    }

    // Note: Ember skills update check is performed in ContentView.task (Issue #263)
    
    // Check for worker mode (--worker flag)
    // Headless mode uses the persisted swarm role from DeviceSettings (not hardcoded to .worker)
    // so that machines configured as hybrid or brain keep their role when launched via self-update.sh
    if WorkerMode.shared.shouldRunInWorkerMode && !Self.isRunningTests {
      _workerModeActive = State(initialValue: true)
      Task { @MainActor in
        let settings = dataService.getDeviceSettings()
        let role = SwarmRole(rawValue: settings.swarmRole) ?? .hybrid
        do {
          try WorkerMode.shared.start(role: role)

          // Wait for Firebase auth (same pattern as auto-start path) so that
          // WebRTC signaling responder and relay provider get initialized.
          let firebaseService = FirebaseService.shared
          if !firebaseService.isSignedIn {
            for _ in 0..<20 {
              try? await Task.sleep(for: .milliseconds(500))
              if firebaseService.isSignedIn { break }
            }
          }

          if firebaseService.isSignedIn {
            let wanAddress = await WANAddressResolver.resolve()
            SwarmCoordinator.shared.setResolvedWANAddress(wanAddress)

            var swarms = firebaseService.memberSwarms
            if swarms.isEmpty {
              for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                swarms = firebaseService.memberSwarms
                if !swarms.isEmpty { break }
              }
            }

            let capabilities = WorkerCapabilities.current(
              wanAddress: wanAddress,
              wanPort: 8766
            )
            for swarm in swarms where swarm.role.canRegisterWorkers {
              _ = try? await firebaseService.registerWorker(swarmId: swarm.id, capabilities: capabilities)
              firebaseService.startWorkerListener(swarmId: swarm.id)
              firebaseService.startMessageListener(swarmId: swarm.id)
            }

            SwarmCoordinator.shared.reinitializeFirestoreServices()
          } else {
            print("Warning: Worker mode — Firebase auth not restored after 10s")
          }
        } catch {
          print("Failed to start worker mode: \(error)")
        }
      }
    }
  }
  
  /// SwiftData model container with two stores:
  /// 1. CloudKit-synced store for shared tracking config (repos, favorites, PRs)
  /// 2. Device-local store for machine-specific state (pull results, local paths)
  static var sharedModelContainer: ModelContainer = {
    let syncedSchema = Schema([
      // Synced to iCloud — shared across devices
      SyncedRepository.self,
      GitHubFavorite.self,
      RecentPullRequest.self,
      TrackedRemoteRepo.self,
      // Other models (kept in synced store for backward compat with existing data)
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
      ChainLearning.self,
      PRReviewQueueItem.self,
    ])

    let localSchema = Schema([
      // Device-local only — never synced via CloudKit
      TrackedRepoDeviceState.self,
    ])

    let fullSchema = Schema([
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
      ChainLearning.self,
      PRReviewQueueItem.self,
      TrackedRepoDeviceState.self,
    ])

    // Existing synced store (unnamed → "default.store", preserves existing data)
    let syncedConfig = ModelConfiguration(
      schema: syncedSchema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .automatic
    )

    // New device-local store for machine-specific pull state
    let localConfig = ModelConfiguration(
      "device-local",
      schema: localSchema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .none
    )

    do {
      return try ModelContainer(for: fullSchema, configurations: [syncedConfig, localConfig])
    } catch {
      // Log error and attempt recovery with in-memory fallback
      print("⚠️ Failed to create persistent ModelContainer: \(error)")
      print("⚠️ Falling back to in-memory storage. Data will not persist.")

      let fallbackSynced = ModelConfiguration(
        schema: syncedSchema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
      )
      let fallbackLocal = ModelConfiguration(
        "device-local",
        schema: localSchema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
      )

      do {
        return try ModelContainer(for: fullSchema, configurations: [fallbackSynced, fallbackLocal])
      } catch {
        // If even in-memory fails, we have a schema problem - this is a programming error
        fatalError("Could not create ModelContainer even with in-memory fallback: \(error)")
      }
    }
  }()
  
  var body: some Scene {
    WindowGroup {
      ContentView()
        #if os(macOS)
        .onAppear {
          appDelegate.daemonModeService = daemonModeService
        }
        #endif
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
          // Handle OAuth callbacks (GitHub auth)
          // Supports both legacy (crunchy-kitchen-sink) and new (peel) schemes
          if (url.scheme == "peel" || url.scheme == "crunchy-kitchen-sink") && url.host == "oauth-callback" {
            OAuthSwift.handle(url: url)
          }
          // Handle swarm invite deep links (peel://swarm/join?s=&i=&t=)
          else if url.scheme == "peel" && url.host == "swarm" {
            Task {
              await FirebaseService.shared.handleDeepLink(url)
              // InvitePreviewSheet is shown automatically via ContentView's
              // onChange listener for pendingInvitePreview
            }
          }
        }
        .task {
          // Check for Ember skills updates on launch (Issue #263)
          let result = await SkillUpdateService.shared.checkForEmberSkillsUpdate()
          if result.hasUpdate {
            skillUpdateAvailable = true
            print("[PeelApp] Ember skills update available")
          }
          // Check for app updates on launch (non-blocking, respects frequency setting)
          let updateState = await AppUpdateService.shared.checkForUpdate()
          if case .available = updateState {
            print("[PeelApp] App update available — user will see it via Check for Updates")
          }
          // Fetch Firestore model registry so MLX model pickers show latest models
          await MLXModelRegistry.shared.fetchIfNeeded()
          // Populate RepoRegistry from SwiftData-backed local paths BEFORE rebuild
          // so unified repository aggregation has the local repo mappings it needs.
          let registry = RepoRegistry.shared
          let localRepoPaths = Array(Set(dataService.getAllLocalRepositoryPaths(validOnly: true).map(\.localPath)))
          await registry.registerAllPaths(localRepoPaths)
          let recentPaths = ReviewLocallyService.shared.recentRepositories.map(\.path)
          await registry.registerAllPaths(recentPaths)
          // Initial rebuild of unified repository data and activity feed.
          // Do this BEFORE RAG operations so the UI is usable quickly.
          repositoryAggregator.rebuild()
          await Task.yield()
          activityFeed.rebuild()
          await Task.yield()
          // Resume any RAG indexing or analysis that was interrupted by the previous app quit.
          // These can be slow (MLX model loading) so run after initial UI is ready.
          await mcpServer.resumeInterruptedRAGOperations()
          // Refresh RAG repo list so rebuild() has current data
          await mcpServer.refreshRagSummary()
          // Re-rebuild with RAG data now available
          repositoryAggregator.rebuild()
        }
        .alert("Ember Best Practices Updated", isPresented: $skillUpdateAvailable) {
          Button("Update Skills") {
            applyEmberSkillsUpdates()
          }
          Button("Later", role: .cancel) {
            // Acknowledge the current remote SHA so we don't re-alert until a new commit lands
            let remoteSHA = UserDefaults.standard.string(forKey: "peel.skills.ember.remoteCommitHash")
            UserDefaults.standard.set(remoteSHA, forKey: "peel.skills.ember.appliedCommitHash")
          }
        } message: {
          Text("New Ember best practices are available from NullVoxPopuli/agent-skills. Apply updated rules to your Ember projects?")
        }
        .environment(mcpServer)
        .environment(vmIsolationService)
        .environment(dataService)
        .environment(repositoryAggregator)
        .environment(activityFeed)
        #if os(macOS)
        .environment(daemonModeService)
        #endif
    }
    .modelContainer(Self.sharedModelContainer)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Peel") {
          showAboutPanel()
        }
        Button("Check for Updates…") {
          Task { await checkForUpdates() }
        }
      }
      CommandGroup(replacing: .help) {
        Button("Peel Help") {
          openHelpWindow()
        }
        .keyboardShortcut("?", modifiers: .command)
      }
      CommandGroup(after: .sidebar) {
        Button("Repositories") {
          UserDefaults.standard.set("repositories", forKey: "current-tool")
        }
        .keyboardShortcut("1", modifiers: .command)

        Button("Activity") {
          UserDefaults.standard.set("activity", forKey: "current-tool")
        }
        .keyboardShortcut("2", modifiers: .command)

        Divider()

        Button("Search Code…") {
          NotificationCenter.default.post(name: .openCommandPalette, object: nil)
        }
        .keyboardShortcut("k", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environment(mcpServer)
        .environment(vmIsolationService)
        .environment(dataService)
        .environment(repositoryAggregator)
        .environment(activityFeed)
        #if os(macOS)
        .environment(daemonModeService)
        #endif
    }
    .modelContainer(Self.sharedModelContainer)
  }

  private func applyEmberSkillsUpdates() {
    let context = dataService.modelContext
    let source = "NullVoxPopuli/agent-skills"
    let descriptor = FetchDescriptor<RepoGuidanceSkill>(
      predicate: #Predicate { $0.source == source }
    )
    let emberSkills = (try? context.fetch(descriptor)) ?? []
    let repoPaths = Set(emberSkills.map { $0.repoPath })
    for repoPath in repoPaths {
      DefaultSkillsService.updateEmberSkills(context: context, repoPath: repoPath)
    }
    // Store the remote SHA we just applied so future checks don't re-alert for the same commit
    let appliedSHA = UserDefaults.standard.string(forKey: "peel.skills.ember.remoteCommitHash")
    UserDefaults.standard.set(appliedSHA, forKey: "peel.skills.ember.appliedCommitHash")
    UserDefaults.standard.set(false, forKey: "peel.skills.ember.updateAvailable")
  }

  private func showAboutPanel() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let commitHash = Bundle.main.object(forInfoDictionaryKey: "PeelGitCommitHash") as? String ?? "dev"
    var versionText = build.isEmpty ? version : "\(version) (\(build))"
    if commitHash != "dev" {
      versionText += " · \(commitHash)"
    }

    guard let donateURL = URL(string: "https://github.com/sponsors/crunchybananas") else { return }
    let credits = NSMutableAttributedString(
      string: "Peel keeps GitHub, git, and Homebrew close at hand so you can stay in flow.\n\nSupport development: "
    )
    let donateLink = NSAttributedString(
      string: "github.com/sponsors/crunchybananas",
      attributes: [
        .link: donateURL,
        .foregroundColor: NSColor.linkColor
      ]
    )
    credits.append(donateLink)

    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Peel",
      .applicationVersion: versionText,
      .credits: credits
    ])
    NSApp.activate(ignoringOtherApps: true)
  }

  private func checkForUpdates() async {
    let state = await AppUpdateService.shared.checkForUpdate(force: true)
    switch state {
    case .available(let info):
      let alert = NSAlert()
      alert.messageText = "Update Available"
      let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
      alert.informativeText = "Peel v\(info.version) is available (you have v\(currentVersion)).\n\n\(info.releaseNotes)"
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Update Now")
      alert.addButton(withTitle: "View Release")
      alert.addButton(withTitle: "Skip This Version")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        await performUpdate(info)
      } else if response == .alertSecondButtonReturn {
        if let url = URL(string: "https://github.com/cloke/peel/releases/tag/\(info.tagName)") {
          NSWorkspace.shared.open(url)
        }
      } else {
        await AppUpdateService.shared.skipVersion(info.version)
      }
    case .upToDate:
      let alert = NSAlert()
      alert.messageText = "You're Up to Date"
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
      let commitHash = Bundle.main.object(forInfoDictionaryKey: "PeelGitCommitHash") as? String ?? "dev"
      alert.informativeText = "Peel v\(version) (\(commitHash)) is the latest version."
      alert.alertStyle = .informational
      alert.runModal()
    case .error(let message):
      let alert = NSAlert()
      alert.messageText = "Update Check Failed"
      alert.informativeText = message
      alert.alertStyle = .warning
      alert.runModal()
    default:
      break
    }
  }

  private func performUpdate(_ info: AppUpdateService.UpdateInfo) async {
    // Show a progress panel
    let progressPanel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
      styleMask: [.titled, .hudWindow],
      backing: .buffered,
      defer: false
    )
    progressPanel.title = "Updating Peel"
    progressPanel.isFloatingPanel = true
    progressPanel.center()

    let progressIndicator = NSProgressIndicator(frame: NSRect(x: 20, y: 20, width: 300, height: 20))
    progressIndicator.style = .bar
    progressIndicator.minValue = 0
    progressIndicator.maxValue = 1
    progressIndicator.doubleValue = 0
    progressIndicator.isIndeterminate = false

    let label = NSTextField(labelWithString: "Downloading update…")
    label.frame = NSRect(x: 20, y: 55, width: 300, height: 20)
    label.font = .systemFont(ofSize: 13)

    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 100))
    contentView.addSubview(progressIndicator)
    contentView.addSubview(label)
    progressPanel.contentView = contentView
    progressPanel.orderFront(nil)

    do {
      let zipURL = try await AppUpdateService.shared.downloadUpdate(info) { progress in
        Task { @MainActor in
          progressIndicator.doubleValue = progress
        }
      }

      await MainActor.run {
        label.stringValue = "Installing update…"
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
      }

      try await AppUpdateService.shared.installUpdate(from: zipURL)
    } catch {
      progressPanel.close()
      let alert = NSAlert()
      alert.messageText = "Update Failed"
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .critical
      alert.runModal()
    }
  }
  
  private func openHelpWindow() {
    // Create a new window for the help view
    let helpView = HelpView()
    let hostingController = NSHostingController(rootView: helpView)
    
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Peel Help"
    window.setContentSize(NSSize(width: 900, height: 700))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.center()
    window.makeKeyAndOrderFront(nil)
    
    // Keep a reference to prevent deallocation
    NSApp.activate(ignoringOtherApps: true)
  }
}
