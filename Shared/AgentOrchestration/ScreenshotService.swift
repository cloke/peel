#if os(macOS)
import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import ScreenCaptureKit

actor ScreenshotService {
  enum ScreenshotError: Error {
    case permissionDenied
    case captureFailed
    case notSupported
    case noDisplay
  }

  func capture(label: String? = nil) async throws -> URL {
    guard #available(macOS 12.3, *) else {
      throw ScreenshotError.notSupported
    }

    if !CGPreflightScreenCaptureAccess() {
      if !CGRequestScreenCaptureAccess() {
        throw ScreenshotError.permissionDenied
      }
    }

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
      throw ScreenshotError.noDisplay
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.scalesToFit = true
    configuration.showsCursor = true

    let image = try await captureImage(filter: filter, configuration: configuration)

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

  @available(macOS 12.3, *)
  private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      let output = ScreenshotStreamOutput(continuation: continuation)
      let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
      let streamBox = StreamBox(stream: stream)
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
    }
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
#else
actor ScreenshotService {
  func capture(label: String? = nil) async throws -> URL {
    throw NSError(domain: "ScreenshotService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not supported on this platform"]) as Error
  }
}
#endif
