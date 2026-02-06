//
//  DoclingService.swift
//  Peel
//
//  Created on 2/5/26.
//

import Foundation

@MainActor
@Observable
final class DoclingService {
  struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? { message }
  }

  struct Options {
    var inputPath: String
    var outputPath: String
    var pythonPath: String?
    var scriptPath: String?
    var profile: String?

    init(
      inputPath: String,
      outputPath: String,
      pythonPath: String? = nil,
      scriptPath: String? = nil,
      profile: String? = nil
    ) {
      self.inputPath = inputPath
      self.outputPath = outputPath
      self.pythonPath = pythonPath
      self.scriptPath = scriptPath
      self.profile = profile
    }
  }

  struct ConvertResult {
    let inputPath: String
    let outputPath: String
    let bytesWritten: Int
    let pythonPath: String
    let scriptPath: String
  }

  struct InstallResult {
    let pythonPath: String
    let log: String
  }

  var isRunning: Bool = false
  var lastError: String?
  var lastResult: ConvertResult?
  var lastInstallLog: String?

  func runConvert(options: Options) async throws -> ConvertResult {
    let trimmedInput = options.inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedOutput = options.outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInput.isEmpty else { throw ValidationError("Input path is required.") }
    guard !trimmedOutput.isEmpty else { throw ValidationError("Output path is required.") }

    guard let pythonPath = resolvePythonPath(customPath: options.pythonPath) else {
      throw ValidationError("python3 not found. Install Python 3.10+ or set pythonPath.")
    }
    guard let scriptPath = resolveScriptPath(customPath: options.scriptPath) else {
      throw ValidationError("docling-convert.py not found. Run from the repo or set scriptPath.")
    }

    let arguments = [
      scriptPath,
      "--input", expandPath(trimmedInput),
      "--output", expandPath(trimmedOutput)
    ]
    var finalArguments = arguments
    if let profile = options.profile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
      finalArguments.append(contentsOf: ["--profile", profile])
    }

    let result = try await executeProcess(launchPath: pythonPath, arguments: finalArguments)
    if result.exitCode != 0 {
      let message = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
      throw ValidationError(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let outputURL = URL(fileURLWithPath: expandPath(trimmedOutput))
    let bytes = (try? Data(contentsOf: outputURL).count) ?? 0

    let convertResult = ConvertResult(
      inputPath: trimmedInput,
      outputPath: expandPath(trimmedOutput),
      bytesWritten: bytes,
      pythonPath: pythonPath,
      scriptPath: scriptPath
    )
    lastResult = convertResult
    lastError = nil
    return convertResult
  }

  func isDoclingAvailable(pythonPath: String?) async -> Bool {
    guard let pythonPath = resolvePythonPath(customPath: pythonPath) else { return false }
    let args = ["-c", "import docling; print('ok')"]
    if let result = try? await executeProcess(launchPath: pythonPath, arguments: args) {
      return result.exitCode == 0
    }
    return false
  }

  func ensureDoclingInstalled(pythonPath: String? = nil) async throws -> InstallResult {
    var log: [String] = []
    let fm = FileManager.default

    let venvPython = appSupportDoclingVenvPythonPath() ?? ""
    let venvRoot = URL(fileURLWithPath: venvPython)
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    if !fm.fileExists(atPath: venvRoot.path) {
      try fm.createDirectory(at: venvRoot, withIntermediateDirectories: true)
    }

    let bootstrapPython = resolveBootstrapPython(customPath: pythonPath)
    guard let bootstrapPython else {
      throw ValidationError("python3 not found. Install Python 3.10+ to set up Docling.")
    }

    if !fm.isExecutableFile(atPath: venvPython) {
      log.append("$ \(bootstrapPython) -m venv \(venvRoot.path)")
      let result = try await executeProcess(
        launchPath: bootstrapPython,
        arguments: ["-m", "venv", venvRoot.path]
      )
      log.append(result.stdoutString)
      log.append(result.stderrString)
      if result.exitCode != 0 {
        throw ValidationError(result.stderrString.isEmpty ? result.stdoutString : result.stderrString)
      }
    }

    log.append("$ \(venvPython) -m pip install --upgrade pip")
    let pipUpgrade = try await executeProcess(
      launchPath: venvPython,
      arguments: ["-m", "pip", "install", "--upgrade", "pip"]
    )
    log.append(pipUpgrade.stdoutString)
    log.append(pipUpgrade.stderrString)

    log.append("$ \(venvPython) -m pip install docling")
    let pipInstall = try await executeProcess(
      launchPath: venvPython,
      arguments: ["-m", "pip", "install", "docling"]
    )
    log.append(pipInstall.stdoutString)
    log.append(pipInstall.stderrString)
    if pipInstall.exitCode != 0 {
      throw ValidationError(pipInstall.stderrString.isEmpty ? pipInstall.stdoutString : pipInstall.stderrString)
    }

    let logText = log.filter { !$0.isEmpty }.joined(separator: "\n")
    lastInstallLog = logText
    return InstallResult(pythonPath: venvPython, log: logText)
  }

  func suggestedPythonPath() -> String? {
    findPythonPath()
  }

  func suggestedScriptPath() -> String? {
    findScriptPath()
  }

  private func resolvePythonPath(customPath: String?) -> String? {
    if let customPath, !customPath.isEmpty {
      let expanded = expandPath(customPath)
      if FileManager.default.isExecutableFile(atPath: expanded) {
        return expanded
      }
    }
    return findPythonPath()
  }

  private func resolveScriptPath(customPath: String?) -> String? {
    if let customPath, !customPath.isEmpty {
      let expanded = expandPath(customPath)
      if FileManager.default.fileExists(atPath: expanded) {
        return expanded
      }
    }
    return findScriptPath()
  }

  private func findScriptPath() -> String? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let roots = [
      fm.currentDirectoryPath,
      home,
      URL(fileURLWithPath: home).appendingPathComponent("code").path,
      URL(fileURLWithPath: home).appendingPathComponent("projects").path,
      Bundle.main.bundleURL.deletingLastPathComponent().path
    ]

    var detected: [String] = []
    for root in roots {
      if let ancestor = findAncestor(containing: "Tools/docling-convert.py", from: root) {
        detected.append(ancestor)
      }
    }

    for root in Array(Set(detected)) {
      let scriptPath = URL(fileURLWithPath: root)
        .appendingPathComponent("Tools/docling-convert.py")
        .path
      if fm.fileExists(atPath: scriptPath) { return scriptPath }
    }

    return nil
  }

  private func findPythonPath() -> String? {
    let fm = FileManager.default
    if let appSupport = appSupportDoclingVenvPythonPath(),
       fm.isExecutableFile(atPath: appSupport) {
      return appSupport
    }

    let devVenv = URL(fileURLWithPath: fm.currentDirectoryPath)
      .appendingPathComponent("tmp/docling-venv/bin/python")
      .path
    if fm.isExecutableFile(atPath: devVenv) { return devVenv }

    return findExecutable("python3")
  }

  private func resolveBootstrapPython(customPath: String?) -> String? {
    if let customPath, !customPath.isEmpty {
      let expanded = expandPath(customPath)
      if FileManager.default.isExecutableFile(atPath: expanded) {
        return expanded
      }
    }
    return findExecutable("python3")
  }

  private func appSupportDoclingVenvPythonPath() -> String? {
    let fm = FileManager.default
    guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    return base
      .appendingPathComponent("Peel")
      .appendingPathComponent("docling-venv/bin/python")
      .path
  }

  private func expandPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("~") {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return trimmed.replacingOccurrences(of: "~", with: home)
    }
    if trimmed.hasPrefix("/") {
      return trimmed
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(trimmed)
      .path
  }

  private func findAncestor(containing relativePath: String, from start: String) -> String? {
    var url = URL(fileURLWithPath: start)
    let fm = FileManager.default
    while true {
      let candidate = url.appendingPathComponent(relativePath).path
      if fm.fileExists(atPath: candidate) {
        return url.path
      }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { break }
      url = parent
    }
    return nil
  }

  private func findExecutable(_ name: String) -> String? {
    let paths = [
      "/opt/homebrew/bin/\(name)",
      "/usr/local/bin/\(name)",
      "/usr/bin/\(name)",
      "/bin/\(name)"
    ]

    for path in paths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }
    return nil
  }

  private struct ExecutionResult {
    let stdoutString: String
    let stderrString: String
    let exitCode: Int32
  }

  private func executeProcess(launchPath: String, arguments: [String]) async throws -> ExecutionResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
          return
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
        continuation.resume(returning: ExecutionResult(
          stdoutString: stdoutString,
          stderrString: stderrString,
          exitCode: process.terminationStatus
        ))
      }
    }
  }
}
