//
//  DaemonModeService.swift
//  Peel
//
//  Created by Peel Agent on 2026-06-28.
//
//  Manages daemon mode: background-app lifecycle, login item registration,
//  and menu bar status indicator. When enabled, closing the window keeps
//  the MCP server running in the background instead of quitting the app.
//

#if os(macOS)
import AppKit
import Foundation
import OSLog
import ServiceManagement

@MainActor
@Observable
final class DaemonModeService {
  private let logger = Logger(subsystem: "crunchy-bananas.Peel", category: "DaemonMode")

  // MARK: - State

  /// Whether the app is currently running in background mode (no visible windows).
  private(set) var isBackgroundMode = false

  // MARK: - Settings
  // Stored properties so @Observable can track them for SwiftUI updates.

  /// When true, closing the last window enters background mode instead of quitting.
  var runInBackground: Bool {
    didSet {
      UserDefaults.standard.set(runInBackground, forKey: StorageKey.runInBackground)
      if !runInBackground && isBackgroundMode {
        bringToForeground()
      }
    }
  }

  /// Whether the app is registered as a login item.
  var startAtLogin: Bool {
    didSet {
      guard startAtLogin != oldValue else { return }
      setLoginItemEnabled(startAtLogin)
    }
  }

  /// Human-readable status of the login item registration.
  var loginItemStatus: String {
    switch SMAppService.mainApp.status {
    case .enabled: "Enabled"
    case .notRegistered: "Not registered"
    case .notFound: "Not found"
    case .requiresApproval: "Requires approval in System Settings"
    @unknown default: "Unknown"
    }
  }

  init() {
    self.runInBackground = UserDefaults.standard.bool(forKey: StorageKey.runInBackground)
    self.startAtLogin = SMAppService.mainApp.status == .enabled
  }

  // MARK: - Login Item

  private func setLoginItemEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
        logger.info("Registered as login item")
      } else {
        try SMAppService.mainApp.unregister()
        logger.info("Unregistered login item")
      }
    } catch {
      logger.error("Login item registration failed: \(error)")
      // Revert local state to match actual status
      startAtLogin = SMAppService.mainApp.status == .enabled
    }
  }

  // MARK: - Background Mode

  /// Enter background mode — hides from dock, shows menu bar icon.
  /// Called when the last window closes and `runInBackground` is true.
  func enterBackgroundMode() {
    guard !isBackgroundMode else { return }
    isBackgroundMode = true
    NSApp.setActivationPolicy(.accessory)
    showStatusItem()
    logger.info("Entered background mode — MCP server continues running")
  }

  /// Return to foreground — shows in dock, reopens window, hides menu bar icon.
  func bringToForeground() {
    guard isBackgroundMode else { return }
    isBackgroundMode = false
    NSApp.setActivationPolicy(.regular)
    hideStatusItem()

    // If any windows survived (hidden), bring them back.
    // Otherwise SwiftUI's WindowGroup will create a new one on activate.
    let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.className.contains("StatusBar") }
    if !hasVisibleWindow {
      for window in NSApp.windows where !window.className.contains("StatusBar") {
        window.makeKeyAndOrderFront(nil)
        break
      }
    }

    NSApp.activate(ignoringOtherApps: true)
    logger.info("Brought to foreground")
  }

  /// Called by the app delegate to decide whether closing the last window should quit.
  func shouldTerminateAfterLastWindowClosed() -> Bool {
    if runInBackground {
      enterBackgroundMode()
      return false
    }
    return true
  }

  // MARK: - Menu Bar Status Item

  private var statusItem: NSStatusItem?
  private var statusBarDelegate: StatusBarDelegate?

  private func showStatusItem() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "server.rack",
        accessibilityDescription: "Peel MCP Server"
      )
    }

    let delegate = StatusBarDelegate(
      onOpen: { [weak self] in self?.bringToForeground() },
      onQuit: { NSApp.terminate(nil) }
    )

    let menu = NSMenu()

    let headerItem = NSMenuItem(title: "Peel MCP Server", action: nil, keyEquivalent: "")
    headerItem.isEnabled = false
    menu.addItem(headerItem)

    menu.addItem(.separator())

    let openItem = NSMenuItem(
      title: "Open Peel",
      action: #selector(StatusBarDelegate.handleOpen),
      keyEquivalent: "o"
    )
    openItem.target = delegate
    menu.addItem(openItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit Peel",
      action: #selector(StatusBarDelegate.handleQuit),
      keyEquivalent: "q"
    )
    quitItem.target = delegate
    menu.addItem(quitItem)

    item.menu = menu
    statusItem = item
    statusBarDelegate = delegate
  }

  private func hideStatusItem() {
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
      statusBarDelegate = nil
    }
  }

  // MARK: - Storage Keys

  private enum StorageKey {
    static let runInBackground = "peel.daemon.runInBackground"
  }
}

// MARK: - Status Bar Action Delegate

/// Helper class that provides @objc selector targets for NSMenuItem actions.
@MainActor
private final class StatusBarDelegate: NSObject {
  let onOpen: @MainActor () -> Void
  let onQuit: @MainActor () -> Void

  init(onOpen: @escaping @MainActor () -> Void, onQuit: @escaping @MainActor () -> Void) {
    self.onOpen = onOpen
    self.onQuit = onQuit
  }

  @objc func handleOpen() { onOpen() }
  @objc func handleQuit() { onQuit() }
}
#endif
