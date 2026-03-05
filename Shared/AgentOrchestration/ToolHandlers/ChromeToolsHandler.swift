//
//  ChromeToolsHandler.swift
//  Peel
//
//  MCP tool handler for Chrome browser automation in parallel UX testing.
//  Provides chrome.launch, chrome.navigate, chrome.screenshot, chrome.diff,
//  chrome.snapshot, chrome.close, and chrome.status tools.
//
//  Each parallel agent gets its own Chrome instance + dev server via UXTestOrchestrator.
//

import Foundation
import CoreGraphics
import ImageIO
import MCPCore
import os

private let logger = Logger(subsystem: "com.crunchy-bananas.peel", category: "ChromeToolsHandler")

/// Handles Chrome browser automation tools for parallel UX testing.
@MainActor
public final class ChromeToolsHandler: MCPToolHandler {
  public weak var delegate: MCPToolHandlerDelegate?

  /// The UX test orchestrator that manages Chrome + dev server sessions
  var orchestrator: UXTestOrchestrator?

  public let supportedTools: Set<String> = [
    "chrome.launch",
    "chrome.navigate",
    "chrome.screenshot",
    "chrome.diff",
    "chrome.emulate",
    "chrome.snapshot",
    "chrome.evaluate",
    "chrome.fill",
    "chrome.click",
    "chrome.wait",
    "chrome.select",
    "chrome.check",
    "chrome.interceptRequest",
    "chrome.getNetworkLog",
    "chrome.close",
    "chrome.status"
  ]

  public init() {}

  public func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    guard let orchestrator else {
      return serviceNotActiveError(id: id, service: "UX Test Orchestrator",
        hint: "UX testing is not initialized. The orchestrator must be configured before using Chrome tools.")
    }

    switch name {
    case "chrome.launch":
      return await handleLaunch(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.navigate":
      return await handleNavigate(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.screenshot":
      return await handleScreenshot(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.diff":
      return handleDiff(id: id, arguments: arguments)
    case "chrome.emulate":
      return await handleEmulate(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.snapshot":
      return await handleSnapshot(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.evaluate":
      return await handleEvaluate(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.fill":
      return await handleFill(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.click":
      return await handleClick(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.wait":
      return await handleWait(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.select":
      return await handleSelect(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.check":
      return await handleCheck(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.interceptRequest":
      return await handleInterceptRequest(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.getNetworkLog":
      return await handleGetNetworkLog(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.close":
      return await handleClose(id: id, arguments: arguments, orchestrator: orchestrator)
    case "chrome.status":
      return handleStatus(id: id, orchestrator: orchestrator)
    default:
      return (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.methodNotFound, message: "Unknown tool"))
    }
  }

  // MARK: - chrome.launch

  /// Launch a new UX test session: allocate ports, optionally start FE dev server, launch headless Chrome.
  private func handleLaunch(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    // worktreePath is optional when skipDevServer is true — use a temp path
    let skipDevServer = arguments["skipDevServer"] as? Bool ?? false
    let worktreePath: String
    if let wp = optionalString("worktreePath", from: arguments), !wp.isEmpty {
      worktreePath = wp
    } else if skipDevServer {
      worktreePath = NSTemporaryDirectory()
    } else {
      return missingParamError(id: id, param: "worktreePath")
    }

    let sessionIdStr = optionalString("sessionId", from: arguments)
    let sessionId: UUID
    if let str = sessionIdStr, let parsed = UUID(uuidString: str) {
      sessionId = parsed
    } else {
      sessionId = UUID()
    }

    // Optional: API base URL for the shared backend
    let apiBaseURL = optionalString("apiBaseURL", from: arguments) ?? "http://localhost:3000"

    do {
      let session = try await orchestrator.createSession(
        sessionId: sessionId,
        worktreePath: worktreePath,
        skipDevServer: skipDevServer
      )

      logger.info("Launched UX session \(session.id.uuidString) for \(worktreePath) skipDevServer:\(skipDevServer)")

      var result: [String: Any] = [
        "sessionId": session.id.uuidString,
        "chromeDebugPort": session.chromeDebugPort,
        "apiBaseURL": apiBaseURL,
        "status": session.statusDescription,
      ]

      if !skipDevServer {
        result["devServerURL"] = session.devServerURL
        result["devServerPort"] = session.devServerPort
        result["message"] = "UX session launched. Dev server at \(session.devServerURL), Chrome ready. "
          + "Use chrome.navigate to load a page, then chrome.screenshot to verify."
      } else {
        result["message"] = "UX session launched (browser only, no dev server). Chrome ready. "
          + "Use chrome.navigate with a full URL, then chrome.screenshot to verify."
      }

      return (200, makeResult(id: id, result: result))
    } catch {
      logger.error("Failed to launch UX session: \(error.localizedDescription)")
      return internalError(id: id, message: "Failed to launch UX session: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.navigate

  private func handleNavigate(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let url) = requireString("url", from: arguments, id: id) else {
      return missingParamError(id: id, param: "url")
    }

    // If url is a relative path, prepend the dev server URL
    let fullURL: String
    if url.hasPrefix("/") {
      guard let session = orchestrator.sessions[sessionId] else {
        return notFoundError(id: id, what: "Session \(sessionIdStr)")
      }
      fullURL = "\(session.devServerURL)\(url)"
    } else {
      fullURL = url
    }

    do {
      let title = try await orchestrator.chromeManager.navigate(sessionId: sessionId, url: fullURL)
      return (200, makeResult(id: id, result: [
        "url": fullURL,
        "title": title,
        "message": "Navigated to \(fullURL) — page title: \(title)"
      ]))
    } catch {
      return internalError(id: id, message: "Navigation failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.screenshot

  private func handleScreenshot(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    let format = optionalString("format", from: arguments) ?? "png"
    let savePath = optionalString("savePath", from: arguments)

    do {
      let filePath = try await orchestrator.screenshot(sessionId: sessionId)

      // If savePath specified, copy to that location
      var effectivePath = filePath
      if let savePath, !savePath.isEmpty {
        let saveDir = (savePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: filePath, toPath: savePath)
        effectivePath = savePath
      }

      return (200, makeResult(id: id, result: [
        "filePath": effectivePath,
        "format": format,
        "message": "Screenshot saved to \(effectivePath)"
      ]))
    } catch {
      return internalError(id: id, message: "Screenshot failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.snapshot

  // MARK: - chrome.diff

  private func handleDiff(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    guard case .success(let beforePath) = requireString("beforePath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "beforePath")
    }
    guard case .success(let afterPath) = requireString("afterPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "afterPath")
    }

    let threshold = max(0, min(255, arguments["threshold"] as? Int ?? 16))

    do {
      guard FileManager.default.fileExists(atPath: beforePath) else {
        return notFoundError(id: id, what: "Before image not found at \(beforePath)")
      }
      guard FileManager.default.fileExists(atPath: afterPath) else {
        return notFoundError(id: id, what: "After image not found at \(afterPath)")
      }

      let beforeRaster = try loadRasterImage(atPath: beforePath)
      let afterRaster = try loadRasterImage(atPath: afterPath)

      guard beforeRaster.width == afterRaster.width,
            beforeRaster.height == afterRaster.height else {
        return invalidParamError(
          id: id,
          param: "beforePath/afterPath",
          reason: "Image dimensions must match for diffing (before: \(beforeRaster.width)x\(beforeRaster.height), after: \(afterRaster.width)x\(afterRaster.height))"
        )
      }

      var diffPixels = [UInt8](repeating: 0, count: beforeRaster.pixels.count)
      var changedPixels = 0

      for index in stride(from: 0, to: beforeRaster.pixels.count, by: 4) {
        let bR = beforeRaster.pixels[index]
        let bG = beforeRaster.pixels[index + 1]
        let bB = beforeRaster.pixels[index + 2]
        let bA = beforeRaster.pixels[index + 3]

        let aR = afterRaster.pixels[index]
        let aG = afterRaster.pixels[index + 1]
        let aB = afterRaster.pixels[index + 2]
        let aA = afterRaster.pixels[index + 3]

        let maxDelta = max(
          abs(Int(bR) - Int(aR)),
          max(
            abs(Int(bG) - Int(aG)),
            max(abs(Int(bB) - Int(aB)), abs(Int(bA) - Int(aA)))
          )
        )

        if maxDelta > threshold {
          changedPixels += 1
          diffPixels[index] = 255
          diffPixels[index + 1] = 0
          diffPixels[index + 2] = 0
          diffPixels[index + 3] = 255
        } else {
          let luminance = UInt8((Int(bR) * 30 + Int(bG) * 59 + Int(bB) * 11) / 100)
          diffPixels[index] = luminance
          diffPixels[index + 1] = luminance
          diffPixels[index + 2] = luminance
          diffPixels[index + 3] = 180
        }
      }

      let totalPixels = beforeRaster.width * beforeRaster.height
      let percentChanged = totalPixels > 0
      ? (Double(changedPixels) / Double(totalPixels)) * 100
      : 0

      let outputPath = try resolveDiffPath(from: arguments, beforePath: beforePath, afterPath: afterPath)
      try writePNG(path: outputPath, width: beforeRaster.width, height: beforeRaster.height, rgbaPixels: diffPixels)

      return (200, makeResult(id: id, result: [
        "beforePath": beforePath,
        "afterPath": afterPath,
        "diffPath": outputPath,
        "threshold": threshold,
        "width": beforeRaster.width,
        "height": beforeRaster.height,
        "pixelsChanged": changedPixels,
        "totalPixels": totalPixels,
        "percentChanged": percentChanged,
        "message": "Diff created at \(outputPath) (\(changedPixels)/\(totalPixels) pixels changed)"
      ]))
    } catch {
      return internalError(id: id, message: "Diff failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.emulate

  private func handleEmulate(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    let presetName = optionalString("preset", from: arguments)?.lowercased()
    let preset = presetName.flatMap { viewportPresets[$0] }

    let width = (arguments["width"] as? Int) ?? preset?.width
    let height = (arguments["height"] as? Int) ?? preset?.height
    let deviceScaleFactor = (arguments["deviceScaleFactor"] as? Double) ?? preset?.deviceScaleFactor ?? 1
    let mobile = (arguments["mobile"] as? Bool) ?? preset?.mobile ?? false

    guard let width, let height else {
      return invalidParamError(
        id: id,
        param: "width/height",
        reason: "Provide width and height, or choose a preset (iphone-se, iphone-14-pro, ipad, desktop)"
      )
    }

    do {
      try await orchestrator.chromeManager.emulate(
        sessionId: sessionId,
        width: width,
        height: height,
        deviceScaleFactor: deviceScaleFactor,
        mobile: mobile
      )

      return (200, makeResult(id: id, result: [
        "sessionId": sessionIdStr,
        "preset": presetName as Any,
        "width": width,
        "height": height,
        "deviceScaleFactor": deviceScaleFactor,
        "mobile": mobile,
        "message": "Applied viewport emulation \(width)x\(height) dpr:\(deviceScaleFactor) mobile:\(mobile)"
      ]))
    } catch {
      return internalError(id: id, message: "Viewport emulation failed: \(error.localizedDescription)")
    }
  }

  private struct ViewportPreset {
    let width: Int
    let height: Int
    let deviceScaleFactor: Double
    let mobile: Bool
  }

  private let viewportPresets: [String: ViewportPreset] = [
    "iphone-se": ViewportPreset(width: 375, height: 667, deviceScaleFactor: 2, mobile: true),
    "iphone-14-pro": ViewportPreset(width: 393, height: 852, deviceScaleFactor: 3, mobile: true),
    "ipad": ViewportPreset(width: 810, height: 1080, deviceScaleFactor: 2, mobile: true),
    "desktop": ViewportPreset(width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
  ]

  private struct RasterImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]
  }

  private func loadRasterImage(atPath path: String) throws -> RasterImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw NSError(domain: "ChromeToolsHandler", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Unable to read image at \(path)"
      ])
    }

    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw NSError(domain: "ChromeToolsHandler", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Unable to create bitmap context for \(path)"
      ])
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RasterImage(width: width, height: height, pixels: pixels)
  }

  private func resolveDiffPath(from arguments: [String: Any], beforePath: String, afterPath: String) throws -> String {
    if let explicit = optionalString("diffPath", from: arguments), !explicit.isEmpty {
      let dir = (explicit as NSString).deletingLastPathComponent
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      return explicit
    }

    let baseDir = (afterPath as NSString).deletingLastPathComponent
    let beforeName = URL(fileURLWithPath: beforePath).deletingPathExtension().lastPathComponent
    let afterName = URL(fileURLWithPath: afterPath).deletingPathExtension().lastPathComponent
    let filename = "diff-\(beforeName)-vs-\(afterName)-\(UUID().uuidString.prefix(8)).png"
    let resolved = (baseDir as NSString).appendingPathComponent(filename)
    try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
    return resolved
  }

  private func writePNG(path: String, width: Int, height: Int, rgbaPixels: [UInt8]) throws {
    guard let provider = CGDataProvider(data: Data(rgbaPixels) as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
      throw NSError(domain: "ChromeToolsHandler", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Unable to create diff image buffer"
      ])
    }

    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
      throw NSError(domain: "ChromeToolsHandler", code: 4, userInfo: [
        NSLocalizedDescriptionKey: "Unable to create PNG destination at \(path)"
      ])
    }

    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) {
      throw NSError(domain: "ChromeToolsHandler", code: 5, userInfo: [
        NSLocalizedDescriptionKey: "Failed to write diff PNG at \(path)"
      ])
    }
  }

  private func handleSnapshot(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    do {
      let domTree = try await orchestrator.snapshot(sessionId: sessionId)
      return (200, makeResult(id: id, result: [
        "snapshot": domTree,
        "message": "DOM snapshot captured (\(domTree.count) chars)"
      ]))
    } catch {
      return internalError(id: id, message: "Snapshot failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.evaluate

  private func handleEvaluate(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let expression) = requireString("expression", from: arguments, id: id) else {
      return missingParamError(id: id, param: "expression")
    }

    let awaitPromise = arguments["awaitPromise"] as? Bool ?? false

    do {
      let result = try await orchestrator.chromeManager.evaluate(
        sessionId: sessionId,
        expression: expression,
        awaitPromise: awaitPromise
      )

      // Extract the value from the CDP response
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"]
      let resultType = innerResult?["type"] as? String ?? "undefined"

      var response: [String: Any] = [
        "type": resultType,
        "message": "Expression evaluated successfully"
      ]
      if let resultValue {
        response["value"] = resultValue
      }

      return (200, makeResult(id: id, result: response))
    } catch {
      return internalError(id: id, message: "Evaluate failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.fill

  private func handleFill(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let selector) = requireString("selector", from: arguments, id: id) else {
      return missingParamError(id: id, param: "selector")
    }
    guard case .success(let value) = requireString("value", from: arguments, id: id) else {
      return missingParamError(id: id, param: "value")
    }

    // Escape quotes in selector and value for JS injection
    let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    let escapedValue = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

    let js = """
      (function() {
        const el = document.querySelector('\(escapedSelector)');
        if (!el) return { success: false, error: 'No element found matching selector: \(escapedSelector)', url: window.location.href };
        // Focus, clear, set value, and dispatch events to trigger framework bindings
        el.focus();
        el.value = '\(escapedValue)';
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { success: true, tagName: el.tagName, type: el.type || null };
      })()
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"] as? [String: Any] ?? [:]

      if resultValue["success"] as? Bool == true {
        return (200, makeResult(id: id, result: [
          "filled": true,
          "selector": selector,
          "tagName": resultValue["tagName"] ?? "unknown",
          "message": "Filled '\(selector)' with value"
        ]))
      } else {
        let error = resultValue["error"] as? String ?? "Unknown error"
        let url = resultValue["url"] as? String ?? "unknown"
        return (200, makeResult(id: id, result: [
          "filled": false,
          "error": error,
          "currentURL": url,
          "hint": "Use chrome.snapshot to inspect the current DOM and find the correct CSS selector.",
          "message": "Failed to fill: \(error) (page: \(url))"
        ]))
      }
    } catch {
      return internalError(id: id, message: "Fill failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.click

  private func handleClick(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let selector) = requireString("selector", from: arguments, id: id) else {
      return missingParamError(id: id, param: "selector")
    }

    let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

    let js = """
      (function() {
        const el = document.querySelector('\(escapedSelector)');
        if (!el) return { success: false, error: 'No element found matching selector: \(escapedSelector)', url: window.location.href };
        el.click();
        return { success: true, tagName: el.tagName, text: (el.textContent || '').trim().substring(0, 100) };
      })()
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"] as? [String: Any] ?? [:]

      if resultValue["success"] as? Bool == true {
        return (200, makeResult(id: id, result: [
          "clicked": true,
          "selector": selector,
          "tagName": resultValue["tagName"] ?? "unknown",
          "text": resultValue["text"] ?? "",
          "message": "Clicked '\(selector)'"
        ]))
      } else {
        let error = resultValue["error"] as? String ?? "Unknown error"
        let url = resultValue["url"] as? String ?? "unknown"
        return (200, makeResult(id: id, result: [
          "clicked": false,
          "error": error,
          "currentURL": url,
          "hint": "Use chrome.snapshot to inspect the current DOM and find the correct CSS selector.",
          "message": "Failed to click: \(error) (page: \(url))"
        ]))
      }
    } catch {
      return internalError(id: id, message: "Click failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.wait

  private func handleWait(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let selector) = requireString("selector", from: arguments, id: id) else {
      return missingParamError(id: id, param: "selector")
    }

    let timeoutMs = arguments["timeout"] as? Int ?? 5000
    let pollIntervalMs = 250
    let maxAttempts = max(1, timeoutMs / pollIntervalMs)

    let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    let js = "(function() { const el = document.querySelector('\(escapedSelector)'); return el ? { found: true, tagName: el.tagName, visible: el.offsetParent !== null || el.tagName === 'BODY' } : { found: false }; })()"

    for attempt in 1...maxAttempts {
      do {
        let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
        let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
        let resultValue = innerResult?["value"] as? [String: Any] ?? [:]

        if resultValue["found"] as? Bool == true {
          return (200, makeResult(id: id, result: [
            "found": true,
            "selector": selector,
            "tagName": resultValue["tagName"] ?? "unknown",
            "visible": resultValue["visible"] ?? false,
            "attempts": attempt,
            "message": "Element '\(selector)' found after \(attempt) poll(s)"
          ]))
        }
      } catch {
        // Evaluation error — continue polling unless it's the last attempt
        if attempt == maxAttempts {
          return internalError(id: id, message: "Wait failed: \(error.localizedDescription)")
        }
      }

      if attempt < maxAttempts {
        try? await Task.sleep(for: .milliseconds(pollIntervalMs))
      }
    }

    // Timed out — get current URL for debugging context
    var currentURL = "unknown"
    if let urlResult = try? await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: "window.location.href"),
       let urlInner = (urlResult["result"] as? [String: Any])?["result"] as? [String: Any],
       let urlValue = urlInner["value"] as? String {
      currentURL = urlValue
    }

    return (200, makeResult(id: id, result: [
      "found": false,
      "selector": selector,
      "timeout": timeoutMs,
      "currentURL": currentURL,
      "message": "Timed out after \(timeoutMs)ms waiting for '\(selector)'. Current URL: \(currentURL). Try chrome.snapshot to inspect the current DOM."
    ]))
  }

  // MARK: - chrome.select

  private func handleSelect(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let selector) = requireString("selector", from: arguments, id: id) else {
      return missingParamError(id: id, param: "selector")
    }
    guard case .success(let value) = requireString("value", from: arguments, id: id) else {
      return missingParamError(id: id, param: "value")
    }

    let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    let escapedValue = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

    let js = """
      (function() {
        const el = document.querySelector('\(escapedSelector)');
        if (!el) return { success: false, error: 'Element not found: \(escapedSelector)' };
        if (el.tagName !== 'SELECT') return { success: false, error: 'Element is not a <select> (found <' + el.tagName.toLowerCase() + '>)' };
        const option = Array.from(el.options).find(o => o.value === '\(escapedValue)' || o.textContent.trim() === '\(escapedValue)');
        if (!option) {
          const available = Array.from(el.options).map(o => o.value + ' (' + o.textContent.trim() + ')').join(', ');
          return { success: false, error: 'Option not found: \(escapedValue). Available: ' + available };
        }
        el.value = option.value;
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.dispatchEvent(new Event('input', { bubbles: true }));
        return { success: true, selectedValue: option.value, selectedText: option.textContent.trim() };
      })()
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"] as? [String: Any] ?? [:]

      if resultValue["success"] as? Bool == true {
        return (200, makeResult(id: id, result: [
          "selected": true,
          "selector": selector,
          "selectedValue": resultValue["selectedValue"] ?? "",
          "selectedText": resultValue["selectedText"] ?? "",
          "message": "Selected '\(resultValue["selectedText"] ?? value)' in '\(selector)'"
        ]))
      } else {
        let error = resultValue["error"] as? String ?? "Unknown error"
        return (200, makeResult(id: id, result: [
          "selected": false,
          "error": error,
          "message": "Failed to select: \(error)"
        ]))
      }
    } catch {
      return internalError(id: id, message: "Select failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.check

  private func handleCheck(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let selector) = requireString("selector", from: arguments, id: id) else {
      return missingParamError(id: id, param: "selector")
    }

    let checked = arguments["checked"] as? Bool ?? true

    let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")

    let js = """
      (function() {
        const el = document.querySelector('\(escapedSelector)');
        if (!el) return { success: false, error: 'Element not found: \(escapedSelector)' };
        if (el.type !== 'checkbox' && el.type !== 'radio') return { success: false, error: 'Element is not a checkbox or radio (type: ' + (el.type || el.tagName.toLowerCase()) + ')' };
        if (el.checked !== \(checked)) {
          el.checked = \(checked);
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('click', { bubbles: true }));
        }
        return { success: true, checked: el.checked, type: el.type, name: el.name || null };
      })()
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let resultValue = innerResult?["value"] as? [String: Any] ?? [:]

      if resultValue["success"] as? Bool == true {
        return (200, makeResult(id: id, result: [
          "checked": resultValue["checked"] ?? checked,
          "selector": selector,
          "type": resultValue["type"] ?? "unknown",
          "name": resultValue["name"] ?? NSNull(),
          "message": "\(checked ? "Checked" : "Unchecked") '\(selector)'"
        ]))
      } else {
        let error = resultValue["error"] as? String ?? "Unknown error"
        return (200, makeResult(id: id, result: [
          "success": false,
          "error": error,
          "message": "Failed to \(checked ? "check" : "uncheck"): \(error)"
        ]))
      }
    } catch {
      return internalError(id: id, message: "Check failed: \(error.localizedDescription)")
    }
  }

  // MARK: - chrome.close

  // MARK: - chrome.interceptRequest

  private func handleInterceptRequest(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }
    guard case .success(let urlPattern) = requireString("urlPattern", from: arguments, id: id) else {
      return missingParamError(id: id, param: "urlPattern")
    }

    let action = (optionalString("action", from: arguments) ?? "block").lowercased()
    guard action == "block" || action == "mock" else {
      return invalidParamError(id: id, param: "action", reason: "action must be 'block' or 'mock'")
    }

    let method = optionalString("method", from: arguments)?.uppercased()
    let once = arguments["once"] as? Bool ?? false
    let status = arguments["status"] as? Int ?? 503
    let body = optionalString("body", from: arguments) ?? "{\"error\":\"mocked by Peel intercept\"}"
    let headers = arguments["headers"] as? [String: String] ?? ["content-type": "application/json"]

    let config: [String: Any] = [
      "urlPattern": urlPattern,
      "action": action,
      "method": method as Any,
      "once": once,
      "status": status,
      "body": body,
      "headers": headers
    ]

    guard let configLiteral = encodeJSONLiteral(config) else {
      return internalError(id: id, message: "Failed to encode interception config")
    }

    let js = """
      (function(config) {
        if (!window.__peelInterceptors) {
          window.__peelInterceptors = [];
        }

        if (!window.__peelFetchWrapped) {
          const originalFetch = window.fetch.bind(window);
          window.__peelOriginalFetch = originalFetch;
          window.fetch = async function(input, init) {
            const url = typeof input === 'string' ? input : (input && input.url ? input.url : String(input));
            const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();

            const interceptors = window.__peelInterceptors || [];
            for (let i = 0; i < interceptors.length; i++) {
              const it = interceptors[i];
              const methodMatch = !it.method || it.method === method;
              const urlMatch = url.includes(it.urlPattern);
              if (!methodMatch || !urlMatch) continue;

              if (it.once) {
                window.__peelInterceptors.splice(i, 1);
                i -= 1;
              }

              if (it.action === 'block') {
                return Promise.reject(new Error('Request blocked by Peel interceptor: ' + it.urlPattern));
              }

              if (it.action === 'mock') {
                return new Response(it.body || '', {
                  status: it.status || 200,
                  headers: it.headers || { 'content-type': 'application/json' }
                });
              }
            }

            return originalFetch(input, init);
          };
          window.__peelFetchWrapped = true;
        }

        window.__peelInterceptors.push(config);
        return {
          success: true,
          action: config.action,
          urlPattern: config.urlPattern,
          method: config.method || null,
          once: !!config.once,
          activeInterceptorCount: window.__peelInterceptors.length,
          note: 'Fetch interception applies to requests made after this call on the current page context.'
        };
      })(\(configLiteral))
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let value = innerResult?["value"] as? [String: Any] ?? [:]

      return (200, makeResult(id: id, result: [
        "sessionId": sessionIdStr,
        "action": action,
        "urlPattern": urlPattern,
        "method": method as Any,
        "once": once,
        "status": status,
        "activeInterceptorCount": value["activeInterceptorCount"] ?? NSNull(),
        "message": value["note"] ?? "Interception configured"
      ]))
    } catch {
      return internalError(id: id, message: "Request interception setup failed: \(error.localizedDescription)")
    }
  }

  private func encodeJSONLiteral(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: []),
          let result = String(data: data, encoding: .utf8) else {
      return nil
    }
    return result
  }

  // MARK: - chrome.getNetworkLog

  private func handleGetNetworkLog(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    let limit = max(1, min(500, arguments["limit"] as? Int ?? 100))

    let js = """
      (function() {
        const resources = performance.getEntriesByType('resource').map((e) => ({
          name: e.name,
          initiatorType: e.initiatorType || null,
          startTime: Math.round(e.startTime),
          durationMs: Math.round(e.duration),
          transferSize: e.transferSize || 0,
          encodedBodySize: e.encodedBodySize || 0,
          decodedBodySize: e.decodedBodySize || 0,
          nextHopProtocol: e.nextHopProtocol || null,
          renderBlockingStatus: e.renderBlockingStatus || null
        }));

        const navigation = performance.getEntriesByType('navigation')[0] || null;
        const nav = navigation ? {
          type: navigation.type || null,
          domContentLoadedMs: Math.round(navigation.domContentLoadedEventEnd || 0),
          loadEventMs: Math.round(navigation.loadEventEnd || 0),
          responseEndMs: Math.round(navigation.responseEnd || 0),
          transferSize: navigation.transferSize || 0
        } : null;

        const tail = resources.slice(Math.max(0, resources.length - \(limit)));
        return {
          totalResources: resources.length,
          resources: tail,
          navigation: nav,
          sampledLimit: \(limit)
        };
      })()
      """

    do {
      let result = try await orchestrator.chromeManager.evaluate(sessionId: sessionId, expression: js)
      let innerResult = (result["result"] as? [String: Any])?["result"] as? [String: Any]
      let value = innerResult?["value"] as? [String: Any] ?? [:]

      return (200, makeResult(id: id, result: [
        "sessionId": sessionIdStr,
        "totalResources": value["totalResources"] ?? 0,
        "sampledLimit": value["sampledLimit"] ?? limit,
        "navigation": value["navigation"] ?? NSNull(),
        "resources": value["resources"] ?? [],
        "message": "Captured network timing snapshot from Performance API"
      ]))
    } catch {
      return internalError(id: id, message: "Network log capture failed: \(error.localizedDescription)")
    }
  }

  private func handleClose(id: Any?, arguments: [String: Any], orchestrator: UXTestOrchestrator) async -> (Int, Data) {
    guard case .success(let sessionIdStr) = requireString("sessionId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "sessionId")
    }
    guard let sessionId = UUID(uuidString: sessionIdStr) else {
      return invalidParamError(id: id, param: "sessionId", reason: "Invalid UUID format")
    }

    await orchestrator.teardownSession(sessionId: sessionId)
    return (200, makeResult(id: id, result: [
      "message": "UX session \(sessionIdStr) closed. Dev server stopped, Chrome terminated, ports released."
    ]))
  }

  // MARK: - chrome.status

  private func handleStatus(id: Any?, orchestrator: UXTestOrchestrator) -> (Int, Data) {
    let sessions = orchestrator.status()
    let activePorts = orchestrator.sessions.values.map { Int($0.devServerPort) }

    return (200, makeResult(id: id, result: [
      "activeSessions": sessions.count,
      "sessions": sessions,
      "devServerPorts": activePorts,
      "message": sessions.isEmpty
        ? "No active UX test sessions. Use chrome.launch to start one."
        : "\(sessions.count) active UX session(s)"
    ]))
  }

  // MARK: - Tool Definitions

  public var toolDefinitions: [MCPToolDefinition] {
    [
      MCPToolDefinition(
        name: "chrome.launch",
        description: """
          Launch a UX test session: optionally starts a frontend dev server in the given worktree on a unique port \
          and launches a headless Chrome instance. Use skipDevServer=true for browser-only mode (no dev server). \
          Returns the session ID, dev server URL (if applicable), and Chrome debug port. \
          Use chrome.navigate to load pages, chrome.screenshot to capture, chrome.snapshot for DOM tree.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "worktreePath": ["type": "string", "description": "Path to the git worktree containing the frontend project (optional when skipDevServer is true)"],
            "sessionId": ["type": "string", "description": "Optional UUID for the session (auto-generated if omitted)"],
            "apiBaseURL": ["type": "string", "description": "URL of the shared backend API (default: http://localhost:3000)"],
            "skipDevServer": ["type": "boolean", "description": "When true, only launches Chrome without starting a dev server. Useful for testing with existing servers or public URLs."]
          ]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.navigate",
        description: """
          Navigate a Chrome session to a URL. If the URL starts with '/', it's treated as a path \
          relative to the session's dev server (e.g., '/dashboard' → 'http://localhost:3005/dashboard'). \
          Returns the page title after navigation.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "url": ["type": "string", "description": "URL or path to navigate to (e.g., '/dashboard' or 'http://...')"]
          ],
          "required": ["sessionId", "url"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.screenshot",
        description: """
          Capture a screenshot of the current page in a Chrome session. \
          Saves to Application Support/Peel/Screenshots/ and returns the file path. \
          Optionally specify savePath to copy the screenshot to a custom location (e.g., in a worktree). \
          Use this to visually verify UI changes after making code modifications.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "format": ["type": "string", "description": "Image format: 'png' or 'jpeg' (default: png)"],
            "savePath": ["type": "string", "description": "Optional absolute file path to save a copy of the screenshot (e.g., in the agent's worktree)"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chrome.diff",
        description: """
          Compare two screenshot files and generate a visual diff image. \
          Changed pixels are highlighted in red, unchanged regions are dimmed grayscale. \
          Returns diff file path plus change metrics (pixel count and percent).
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "beforePath": ["type": "string", "description": "Absolute file path to baseline screenshot"],
            "afterPath": ["type": "string", "description": "Absolute file path to candidate screenshot"],
            "diffPath": ["type": "string", "description": "Optional absolute output path for diff image (defaults next to afterPath)"],
            "threshold": ["type": "integer", "description": "Per-channel delta threshold 0-255 for marking a pixel as changed (default: 16)"]
          ],
          "required": ["beforePath", "afterPath"]
        ],
        category: .ui,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chrome.emulate",
        description: """
          Emulate viewport/device dimensions for an active Chrome session. \
          Accepts either a named preset or explicit width/height values. \
          Use before navigation/screenshot to validate mobile and tablet layouts.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "preset": ["type": "string", "description": "Optional device preset: iphone-se, iphone-14-pro, ipad, desktop"],
            "width": ["type": "integer", "description": "Viewport width in CSS pixels (required if preset omitted)"],
            "height": ["type": "integer", "description": "Viewport height in CSS pixels (required if preset omitted)"],
            "deviceScaleFactor": ["type": "number", "description": "Optional DPR override (defaults from preset or 1)"],
            "mobile": ["type": "boolean", "description": "Optional mobile behavior override (defaults from preset or false)"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.snapshot",
        description: """
          Get a simplified DOM tree of the current page in a Chrome session. \
          Returns a text representation of the page structure (tag names, IDs, classes, text content). \
          Useful for understanding page layout and finding elements without a screenshot.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chrome.evaluate",
        description: """
          Execute arbitrary JavaScript in a Chrome session and return the result. \
          Use this for complex page interactions that chrome.fill and chrome.click don't cover. \
          The expression is evaluated via Runtime.evaluate in the page context.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "expression": ["type": "string", "description": "JavaScript expression to evaluate in the page context"],
            "awaitPromise": ["type": "boolean", "description": "If true, await the result if it is a Promise (default: false)"]
          ],
          "required": ["sessionId", "expression"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.fill",
        description: """
          Fill in a form field by CSS selector. Sets the value and dispatches input/change events \
          to trigger framework data binding (Ember, React, Vue, etc.). \
          Example selectors: 'input[type=email]', '#password', 'input[name=username]'
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "selector": ["type": "string", "description": "CSS selector for the input element"],
            "value": ["type": "string", "description": "The value to fill into the field"]
          ],
          "required": ["sessionId", "selector", "value"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.click",
        description: """
          Click an element by CSS selector. Finds the first matching element and calls .click(). \
          Example selectors: 'button[type=submit]', '.login-btn', '#sign-in', 'a[href=\"/dashboard\"]'
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "selector": ["type": "string", "description": "CSS selector for the element to click"]
          ],
          "required": ["sessionId", "selector"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.wait",
        description: """
          Wait for a CSS selector to appear in the DOM. Polls at 250ms intervals up to the timeout. \
          Use this after chrome.click on form submits or navigation to wait for the new page content \
          instead of using 'sleep'. Returns whether the element was found and how many poll attempts it took.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "selector": ["type": "string", "description": "CSS selector to wait for (e.g., '.dashboard', '#success-message')"],
            "timeout": ["type": "integer", "description": "Maximum wait time in milliseconds (default: 5000)"]
          ],
          "required": ["sessionId", "selector"]
        ],
        category: .ui,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chrome.select",
        description: """
          Select an option in a <select> dropdown by value or visible text. \
          Dispatches change/input events to trigger framework data binding. \
          If the option isn't found, returns the list of available options for debugging.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "selector": ["type": "string", "description": "CSS selector for the <select> element"],
            "value": ["type": "string", "description": "The option value or visible text to select"]
          ],
          "required": ["sessionId", "selector", "value"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.check",
        description: """
          Check or uncheck a checkbox or radio button by CSS selector. \
          Dispatches change/input/click events. \
          Example: chrome.check with selector='#agree-terms' checked=true
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "selector": ["type": "string", "description": "CSS selector for the checkbox or radio input"],
            "checked": ["type": "boolean", "description": "Target checked state (default: true)"]
          ],
          "required": ["sessionId", "selector"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.interceptRequest",
        description: """
          Configure page-level fetch interception for matching requests. \
          Use action='block' to reject matching fetch calls, or action='mock' to return a synthetic response. \
          Best for testing error states and fallback UI behavior.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "urlPattern": ["type": "string", "description": "Substring match pattern applied to request URL"],
            "action": ["type": "string", "description": "Interception mode: block or mock"],
            "method": ["type": "string", "description": "Optional HTTP method filter (GET, POST, etc.)"],
            "once": ["type": "boolean", "description": "If true, interceptor removes itself after first match"],
            "status": ["type": "integer", "description": "Mock response status (only for action=mock, default 503)"],
            "body": ["type": "string", "description": "Mock response body (only for action=mock)"],
            "headers": ["type": "object", "description": "Mock response headers map (only for action=mock)"]
          ],
          "required": ["sessionId", "urlPattern"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.getNetworkLog",
        description: """
          Capture a network timing snapshot from the browser Performance API for the current page. \
          Returns recent resource entries plus navigation timing details. \
          Useful for auditing heavy assets, slow requests, and render-blocking resources.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session"],
            "limit": ["type": "integer", "description": "Maximum number of recent resource entries to return (default: 100, max: 500)"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: false
      ),
      MCPToolDefinition(
        name: "chrome.close",
        description: """
          Close a UX test session: stops the dev server, terminates Chrome, and releases allocated ports. \
          Always close sessions when done to free resources.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "sessionId": ["type": "string", "description": "UUID of the Chrome session to close"]
          ],
          "required": ["sessionId"]
        ],
        category: .ui,
        isMutating: true
      ),
      MCPToolDefinition(
        name: "chrome.status",
        description: """
          Get status of all active UX test sessions. Shows session IDs, dev server ports/URLs, \
          Chrome debug ports, and readiness state. Use this to see what's running before launching new sessions.
          """,
        inputSchema: [
          "type": "object",
          "properties": [:]
        ],
        category: .ui,
        isMutating: false
      ),
    ]
  }
}
