import Foundation
import AppKit
import ScreenCaptureKit

// ┌─────────────────────────────────────────────────────────────────────┐
// │ IMPORTANT: DO NOT add SCStream-based capture as a fallback.        │
// │                                                                     │
// │ This file has been regressed multiple times by agents adding back   │
// │ old SCStream/startCapture() code. That approach:                    │
// │   - Fails on macOS 26 with "audio/video capture failure"           │
// │   - Requires the app to be frontmost                               │
// │   - Adds ~170 lines of unnecessary helper classes                  │
// │                                                                     │
// │ SCScreenshotManager.captureImage() (macOS 14+) is the correct API. │
// │ It works in the background and captures individual windows cleanly. │
// │                                                                     │
// │ If screenshots fail, the likely causes are:                         │
// │   1. Screen Recording permission not granted in System Settings     │
// │   2. Stage Manager hiding the window (thumbnail ~130px) — the      │
// │      user needs to bring Peel into the active stage                 │
// │   3. findAppWindow returning nil — check bundle ID matching        │
// │                                                                     │
// │ DO NOT "fix" by adding SCStream, CMSampleBuffer, CIContext,        │
// │ ScreenshotStreamOutput, StreamBox, or CaptureCancellationState.    │
// └─────────────────────────────────────────────────────────────────────┘

actor ScreenshotService {
  private var permissionRequested = false

  enum ScreenshotError: Error {
    case permissionDenied
    case captureFailed
    case noWindow
  }

  func capture(label: String? = nil, outputDir: String? = nil) async throws -> URL {
    let hasPermission = await MainActor.run { CGPreflightScreenCaptureAccess() }
    if !hasPermission {
      if permissionRequested {
        throw ScreenshotError.permissionDenied
      }
      permissionRequested = true
      let granted = await MainActor.run { CGRequestScreenCaptureAccess() }
      if !granted {
        throw ScreenshotError.permissionDenied
      }
    }

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = findAppWindow(in: content) else {
      throw ScreenshotError.noWindow
    }

    let configuration = SCStreamConfiguration()
    configuration.scalesToFit = true
    configuration.showsCursor = true
    configuration.width = max(Int(window.frame.width), 1)
    configuration.height = max(Int(window.frame.height), 1)

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )
    return try saveImage(image, label: label, outputDir: outputDir)
  }

  private func saveImage(_ image: CGImage, label: String?, outputDir: String?) throws -> URL {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw ScreenshotError.captureFailed
    }

    let fm = FileManager.default
    let screenshotsDir: URL
    if let outputDir, !outputDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let expandedPath = (outputDir as NSString).expandingTildeInPath
      screenshotsDir = URL(fileURLWithPath: expandedPath, isDirectory: true)
      try? fm.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
    } else {
      let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let peelDir = appSupport.appendingPathComponent("Peel", isDirectory: true)
      screenshotsDir = peelDir.appendingPathComponent("Screenshots", isDirectory: true)
      try? fm.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
    }

    let timestamp = Formatter.iso8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let safeLabel = (label ?? "screenshot").replacingOccurrences(of: " ", with: "_")
    let fileName = "\(timestamp)-\(safeLabel).png"
    let fileURL = screenshotsDir.appendingPathComponent(fileName)

    try data.write(to: fileURL, options: .atomic)
    return fileURL
  }

  // Stage Manager can hide the main window, leaving only a ~130px thumbnail
  // visible. Filter for on-screen windows above a minimum size to avoid
  // capturing menu bar items or Stage Manager thumbnails.
  private func findAppWindow(in content: SCShareableContent) -> SCWindow? {
    guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
    let candidates = content.windows.filter { window in
      guard let app = window.owningApplication else { return false }
      return app.bundleIdentifier == bundleId
        && window.isOnScreen
        && window.frame.width > 50
        && window.frame.height > 50
    }
    // Prefer the largest visible window; fall back to any app window
    if let best = candidates.max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }) {
      return best
    }
    return content.windows.first { window in
      guard let app = window.owningApplication else { return false }
      return app.bundleIdentifier == bundleId && window.frame.width > 50 && window.frame.height > 50
    }
  }
}
