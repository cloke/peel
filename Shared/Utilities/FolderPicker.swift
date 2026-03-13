//
//  FolderPicker.swift
//  KitchenSync
//
//  Created on 1/30/26.
//

import AppKit

/// Shared folder picker utility to eliminate duplication across views
public enum FolderPicker {
  /// Show folder picker panel and return selected path
  /// - Parameters:
  ///   - message: The message displayed to the user (e.g., "Select a project folder")
  ///   - prompt: The button text (default: "Select")
  /// - Returns: The selected folder path, or nil if cancelled
  @MainActor
  public static func selectFolder(
    message: String = "Select a folder",
    prompt: String = "Select"
  ) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = prompt

    if panel.runModal() == .OK, let url = panel.url {
      return url.path
    }
    return nil
  }
}
