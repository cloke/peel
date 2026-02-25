import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import ScreenCaptureKit

actor ScreenshotService {
  private var permissionRequested = false

  enum ScreenshotError: Error {
    case permissionDenied
    case captureFailed
    case notSupported
    case noDisplay
    case timedOut
  }

  func capture(label: String? = nil, outputDir: String? = nil) async throws -> URL {
    guard #available(macOS 12.3, *) else {
      throw ScreenshotError.notSupported
    }

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

    if let image = try await captureAppWindowImage() {
      return try saveImage(image, label: label, outputDir: outputDir)
    }

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard #available(macOS 13.0, *), let window = findAppWindow(in: content) else {
      throw ScreenshotError.noDisplay
    }
    guard let display = content.displays.first else {
      throw ScreenshotError.noDisplay
    }

    let excludedWindows = content.windows.filter { window in
      guard let app = window.owningApplication else { return false }
      return app.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    let configuration = SCStreamConfiguration()
    configuration.scalesToFit = true
    configuration.showsCursor = true
    configuration.width = max(Int(window.frame.width), 1)
    configuration.height = max(Int(window.frame.height), 1)
    configuration.sourceRect = window.frame

    let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

    let image = try await captureImage(filter: filter, configuration: configuration)
    return try saveImage(image, label: label, outputDir: outputDir)
  }

  @available(macOS 12.3, *)
  private func captureAppWindowImage() async throws -> CGImage? {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard #available(macOS 13.0, *), let window = findAppWindow(in: content) else {
      return nil
    }

    let configuration = SCStreamConfiguration()
    configuration.scalesToFit = true
    configuration.showsCursor = true
    configuration.width = max(Int(window.frame.width), 1)
    configuration.height = max(Int(window.frame.height), 1)

    let filter = SCContentFilter(desktopIndependentWindow: window)
    if #available(macOS 14.0, *) {
      return try await captureSingleFrame(filter: filter, configuration: configuration)
    }
    return try await captureImage(filter: filter, configuration: configuration)
  }

  @available(macOS 14.0, *)
  private func captureSingleFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: ScreenshotError.captureFailed)
        }
      }
    }
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

  @available(macOS 12.3, *)
  private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
    let cancellationState = CaptureCancellationState()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let output = ScreenshotStreamOutput(continuation: continuation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        let streamBox = StreamBox(stream: stream)
        cancellationState.configure(output: output, streamBox: streamBox)
        output.attach(stream)

        do {
          try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
        } catch {
          output.failIfNeeded(error)
          return
        }

        Task { [streamBox, output] in
          do {
            try await streamBox.stream.startCapture()
          } catch {
            output.failIfNeeded(error)
          }
        }

        Task { [streamBox, output] in
          do {
            try await Task.sleep(for: .seconds(5))
            output.failIfNeeded(ScreenshotError.timedOut)
          } catch {
            output.failIfNeeded(error)
          }
          try? await streamBox.stream.stopCapture()
        }
      }
    } onCancel: {
      cancellationState.cancel()
    }
  }

  @available(macOS 12.3, *)
  private func findAppWindow(in content: SCShareableContent) -> SCWindow? {
    guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
    let candidates = content.windows.filter { window in
      guard let app = window.owningApplication else { return false }
      return app.bundleIdentifier == bundleId
    }
    return candidates.max(by: { lhs, rhs in
      (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
    })
  }
}


@available(macOS 12.3, *)
private final class ScreenshotStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private var continuation: CheckedContinuation<CGImage, Error>?
  private let context = CIContext()
  private var didFinish = false
  private weak var stream: SCStream?

  init(continuation: CheckedContinuation<CGImage, Error>) {
    self.continuation = continuation
  }

  func attach(_ stream: SCStream) {
    self.stream = stream
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
    guard !didFinish, outputType == .screen else { return }
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let ciImage = CIImage(cvImageBuffer: imageBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

    didFinish = true
    continuation?.resume(returning: cgImage)
    continuation = nil

    let streamBox = StreamBox(stream: stream)
    Task { [streamBox] in
      try? await streamBox.stream.stopCapture()
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    failIfNeeded(error)
  }

  func failIfNeeded(_ error: Error) {
    guard !didFinish else { return }
    didFinish = true
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

@available(macOS 12.3, *)
private final class StreamBox: @unchecked Sendable {
  let stream: SCStream

  init(stream: SCStream) {
    self.stream = stream
  }
}

@available(macOS 12.3, *)
private final class CaptureCancellationState: @unchecked Sendable {
  private var output: ScreenshotStreamOutput?
  private var streamBox: StreamBox?

  func configure(output: ScreenshotStreamOutput, streamBox: StreamBox) {
    self.output = output
    self.streamBox = streamBox
  }

  func cancel() {
    output?.failIfNeeded(CancellationError())
    guard let streamBox else { return }
    Task { [streamBox] in
      try? await streamBox.stream.stopCapture()
    }
  }
}
