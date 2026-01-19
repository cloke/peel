#if os(macOS)
import Foundation
import AppKit
import CoreGraphics

actor ScreenshotService {
  enum ScreenshotError: Error {
    case permissionDenied
    case captureFailed
    case notSupported
  }

  func capture(label: String? = nil) async throws -> URL {
    // Check permission
    if !CGPreflightScreenCaptureAccess() {
      // Request access (may show system prompt)
      if !CGRequestScreenCaptureAccess() {
        throw ScreenshotError.permissionDenied
      }
    }

    guard let image = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
      throw ScreenshotError.captureFailed
    }

    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw ScreenshotError.captureFailed
    }

    let fm = FileManager.default
    let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let peelDir = appSupport.appendingPathComponent("Peel", isDirectory: true)
    let screenshotsDir = peelDir.appendingPathComponent("Screenshots", isDirectory: true)
    try? fm.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let safeLabel = (label ?? "screenshot").replacingOccurrences(of: " ", with: "_")
    let fileName = "\(timestamp)-\(safeLabel).png"
    let fileURL = screenshotsDir.appendingPathComponent(fileName)

    try data.write(to: fileURL, options: .atomic)
    return fileURL
  }
}
#else
actor ScreenshotService {
  func capture(label: String? = nil) async throws -> URL {
    throw NSError(domain: "ScreenshotService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not supported on this platform"]) as Error
  }
}
#endif
