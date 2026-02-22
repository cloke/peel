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

@main
struct PeelApp: App {
  @Environment(\.openURL) var openURL
  @State private var vmIsolationService = VMIsolationService()
  @State private var mcpServer: MCPServerService
  @State private var dataService: DataService
  @State private var workerModeActive = false
  @State private var skillUpdateAvailable = false

  private static var isRunningTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  init() {
    // Configure Firebase first (before other services)
    FirebaseService.shared.configure()
    
    let vmService = VMIsolationService()
    _vmIsolationService = State(initialValue: vmService)
    _mcpServer = State(initialValue: MCPServerService(vmIsolationService: vmService))
    
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

    // Auto-start swarm on launch when device setting enables it (defaults to true for new installs)
    if !Self.isRunningTests {
      Task { @MainActor in
        let settings = dataService.getDeviceSettings()
        // Respect explicit worker-mode flag
        if settings.swarmAutoStart && !WorkerMode.shared.shouldRunInWorkerMode {
          do {
            try SwarmCoordinator.shared.start(role: .hybrid, port: 8766)

            // If signed into Firebase, register worker and start listeners so WAN peers are visible
            if FirebaseService.shared.isSignedIn {
              let wanAddress = await WANAddressResolver.resolve()
              let capabilities = WorkerCapabilities.current(
                wanAddress: wanAddress,
                wanPort: 8766
              )
              for swarm in FirebaseService.shared.memberSwarms where swarm.role.canRegisterWorkers {
                _ = try? await FirebaseService.shared.registerWorker(swarmId: swarm.id, capabilities: capabilities)
                FirebaseService.shared.startWorkerListener(swarmId: swarm.id)
                FirebaseService.shared.startMessageListener(swarmId: swarm.id)
              }
            }
          } catch {
            print("Failed to auto-start swarm: \(error)")
          }
        }
      }
    }
    
    // Note: Ember skills update check is performed in ContentView.task (Issue #263)
    
    // Check for worker mode (--worker flag)
    if WorkerMode.shared.shouldRunInWorkerMode && !Self.isRunningTests {
      _workerModeActive = State(initialValue: true)
      Task { @MainActor in
        do {
          try WorkerMode.shared.start()
        } catch {
          print("Failed to start worker mode: \(error)")
        }
      }
    }
  }
  
  /// SwiftData model container
  /// To enable iCloud later, change cloudKitDatabase to .automatic
  static var sharedModelContainer: ModelContainer = {
    let schema = Schema([
      // Synced to iCloud (when enabled)
      SyncedRepository.self,
      GitHubFavorite.self,
      RecentPullRequest.self,
      // Device-local only
      LocalRepositoryPath.self,
      TrackedWorktree.self,
      SwarmBranchReservation.self,
      DeviceSettings.self,
      MCPRunRecord.self,
      MCPRunResultRecord.self,
      ParallelRunSnapshot.self,
      RepoGuidanceSkill.self,
      CIFailureRecord.self,
      FeatureDiscoveryChecklist.self,
    ])
    
    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .automatic  // Change to .automatic when ready for iCloud
    )
    
    do {
      return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
      // Log error and attempt recovery with in-memory fallback
      print("⚠️ Failed to create persistent ModelContainer: \(error)")
      print("⚠️ Falling back to in-memory storage. Data will not persist.")
      
      let fallbackConfig = ModelConfiguration(
        schema: schema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
      )
      
      do {
        return try ModelContainer(for: schema, configurations: [fallbackConfig])
      } catch {
        // If even in-memory fails, we have a schema problem - this is a programming error
        fatalError("Could not create ModelContainer even with in-memory fallback: \(error)")
      }
    }
  }()
  
  var body: some Scene {
    WindowGroup {
      ContentView()
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
          // Resume any RAG indexing or analysis that was interrupted by the previous app quit
          await mcpServer.resumeInterruptedRAGOperations()
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
    }
    .modelContainer(Self.sharedModelContainer)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Peel") {
          showAboutPanel()
        }
      }
      CommandGroup(replacing: .help) {
        Button("Peel Help") {
          openHelpWindow()
        }
        .keyboardShortcut("?", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environment(mcpServer)
        .environment(vmIsolationService)
        .environment(dataService)
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
    let versionText = build.isEmpty ? version : "\(version) (\(build))"

    let credits = NSMutableAttributedString(
      string: "Peel keeps GitHub, git, and Homebrew close at hand so you can stay in flow.\n\nSupport development: "
    )
    let donateLink = NSAttributedString(
      string: "github.com/sponsors/crunchybananas",
      attributes: [
        .link: URL(string: "https://github.com/sponsors/crunchybananas")!,
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

