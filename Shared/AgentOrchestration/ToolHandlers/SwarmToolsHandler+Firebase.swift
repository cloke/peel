//
//  SwarmToolsHandler+Firebase.swift
//  Peel
//
//  Handles: firebase.emulator.status/install/start/stop/configure
//  Also contains install helpers and emulator helpers.
//  Split from SwarmToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension SwarmToolsHandler {
  // MARK: - Firebase Emulator Tools
  
  /// Cached emulator process reference
  private static var emulatorProcess: Process?
  
  func handleEmulatorInstall(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    var installed: [String] = []
    var alreadyInstalled: [String] = []
    var errors: [String] = []
    
    // Determine what to install (default: all)
    let components = (arguments["components"] as? [String]) ?? ["firebase-tools", "java"]
    
    // Check brew availability
    let brewPath = findBrewPath()
    let npmPath = findExecutable("npm")
    
    // -- Java --
    if components.contains("java") {
      if findExecutable("java") != nil {
        // Verify it actually works (macOS stub returns non-zero)
        let (javaWorks, _) = runCommand("/usr/bin/java", args: ["-version"])
        if javaWorks {
          alreadyInstalled.append("java")
        } else {
          // Install Temurin JDK via brew
          if let brew = brewPath {
            let (ok, output) = runCommand(brew, args: ["install", "--cask", "temurin"])
            if ok {
              installed.append("java (temurin)")
            } else {
              errors.append("java: brew install failed — \(output)")
            }
          } else {
            errors.append("java: brew not found, install manually with: brew install --cask temurin")
          }
        }
      } else {
        if let brew = brewPath {
          let (ok, output) = runCommand(brew, args: ["install", "--cask", "temurin"])
          if ok {
            installed.append("java (temurin)")
          } else {
            errors.append("java: brew install failed — \(output)")
          }
        } else {
          errors.append("java: brew not found, install manually with: brew install --cask temurin")
        }
      }
    }
    
    // -- firebase-tools --
    if components.contains("firebase-tools") {
      if findExecutable("firebase") != nil {
        alreadyInstalled.append("firebase-tools")
      } else if let npm = npmPath {
        let (ok, output) = runCommand(npm, args: ["install", "-g", "firebase-tools"])
        if ok {
          installed.append("firebase-tools")
        } else {
          errors.append("firebase-tools: npm install failed — \(output)")
        }
      } else if let brew = brewPath {
        let (ok, output) = runCommand(brew, args: ["install", "firebase-cli"])
        if ok {
          installed.append("firebase-tools")
        } else {
          errors.append("firebase-tools: brew install failed — \(output)")
        }
      } else {
        errors.append("firebase-tools: neither npm nor brew found")
      }
    }
    
    let success = errors.isEmpty
    return (200, makeResult(id: id, result: [
      "success": success,
      "installed": installed,
      "alreadyInstalled": alreadyInstalled,
      "errors": errors,
      "hint": success
        ? "All dependencies ready. Use firebase.emulator.start to launch emulators."
        : "Some installs failed. Fix errors above and retry."
    ]))
  }
  
  // MARK: - Install Helpers
  
  private func findBrewPath() -> String? {
    let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
  }
  
  private func findExecutable(_ name: String) -> String? {
    let paths = [
      "/opt/homebrew/bin/\(name)",
      "/usr/local/bin/\(name)",
      "/usr/bin/\(name)"
    ]
    // Also check NVM paths for npm/node
    if let home = ProcessInfo.processInfo.environment["HOME"] {
      let nvmDefault = "\(home)/.nvm/versions/node" 
      if let nodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDefault) {
        for version in nodeVersions.sorted().reversed() {
          let candidate = "\(nvmDefault)/\(version)/bin/\(name)"
          if FileManager.default.fileExists(atPath: candidate) {
            return candidate
          }
        }
      }
    }
    return paths.first { FileManager.default.fileExists(atPath: $0) }
  }
  
  private func runCommand(_ executable: String, args: [String]) -> (Bool, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    // Inherit PATH so brew/npm can find dependencies
    var env = ProcessInfo.processInfo.environment
    if let brew = findBrewPath() {
      let brewBin = (brew as NSString).deletingLastPathComponent
      env["PATH"] = "\(brewBin):\(env["PATH"] ?? "/usr/bin:/bin")"
    }
    process.environment = env
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return (process.terminationStatus == 0, output)
    } catch {
      return (false, error.localizedDescription)
    }
  }
  
  func handleEmulatorStatus(id: Any?) -> (Int, Data) {
    let service = FirebaseService.shared
    
    // Check if emulator process is running
    let processRunning = Self.emulatorProcess?.isRunning == true
    
    // Check if emulators are reachable
    var firestoreReachable = false
    var authReachable = false
    let host = service.emulatorHost ?? "localhost"
    
    // Quick TCP check for Firestore (8080) and Auth (9099)
    firestoreReachable = checkPort(host: host, port: 8080)
    authReachable = checkPort(host: host, port: 9099)
    
    return (200, makeResult(id: id, result: [
      "usingEmulators": service.isUsingEmulators,
      "emulatorHost": service.emulatorHost as Any,
      "processRunning": processRunning,
      "firestoreReachable": firestoreReachable,
      "authReachable": authReachable,
      "firestorePort": 8080,
      "authPort": 9099,
      "uiPort": 4000,
      "uiURL": "http://\(host):4000",
      "configuredVia": service.isUsingEmulators 
        ? (ProcessInfo.processInfo.environment["FIREBASE_EMULATOR_HOST"] != nil ? "environment" : "userDefaults")
        : "not configured",
      "hint": service.isUsingEmulators 
        ? "Emulator mode active. Firestore UI at http://\(host):4000"
        : "Set FIREBASE_EMULATOR_HOST env var or use firebase.emulator.configure to enable."
    ]))
  }
  
  func handleEmulatorStart(id: Any?, arguments: [String: Any]) async -> (Int, Data) {
    let lan = optionalBool("lan", from: arguments, default: false)
    let seed = optionalBool("seed", from: arguments, default: false)
    
    // Check if already running
    if Self.emulatorProcess?.isRunning == true {
      return (200, makeResult(id: id, result: [
        "success": true,
        "alreadyRunning": true,
        "message": "Firebase emulators already running"
      ]))
    }
    
    // Find the script
    let scriptPath = findProjectRoot() + "/Tools/firebase-emulator.sh"
    guard FileManager.default.fileExists(atPath: scriptPath) else {
      return internalError(id: id, message: "firebase-emulator.sh not found at \(scriptPath). Run from the project directory.")
    }
    
    // Check firebase CLI is available
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = ["firebase"]
    let whichPipe = Pipe()
    whichProcess.standardOutput = whichPipe
    whichProcess.standardError = whichPipe
    do {
      try whichProcess.run()
      whichProcess.waitUntilExit()
      if whichProcess.terminationStatus != 0 {
        return internalError(id: id, message: "firebase-tools not installed. Run: npm install -g firebase-tools")
      }
    } catch {
      return internalError(id: id, message: "Could not check for firebase CLI: \(error.localizedDescription)")
    }
    
    // Build arguments
    var args = [scriptPath]
    if lan { args.append("--lan") }
    if seed { args.append("--seed") }
    
    // Launch emulator process in background
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", args.joined(separator: " ")]
    process.currentDirectoryURL = URL(fileURLWithPath: findProjectRoot())
    
    // Capture output
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    
    do {
      try process.run()
      Self.emulatorProcess = process
      
      // Wait a few seconds for emulators to start
      try? await Task.sleep(for: .seconds(5))
      
      let host = lan ? getLocalIP() : "localhost"
      let running = checkPort(host: host, port: 8080)
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "pid": process.processIdentifier,
        "lan": lan,
        "host": host,
        "firestoreReady": running,
        "uiURL": "http://\(host):4000",
        "hint": running 
          ? "Emulators running. Configure the app with: firebase.emulator.configure host=\(host)"
          : "Emulators starting... check again in a few seconds with firebase.emulator.status"
      ]))
    } catch {
      return internalError(id: id, message: "Failed to start emulators: \(error.localizedDescription)")
    }
  }
  
  func handleEmulatorStop(id: Any?) async -> (Int, Data) {
    if let process = Self.emulatorProcess, process.isRunning {
      process.terminate()
      // Give it a moment to shut down
      try? await Task.sleep(for: .seconds(2))
      if process.isRunning {
        process.interrupt()
      }
      Self.emulatorProcess = nil
      return (200, makeResult(id: id, result: [
        "success": true,
        "message": "Emulators stopped"
      ]))
    }
    
    // Try pkill as fallback (emulators may have been started externally)
    let pkillProcess = Process()
    pkillProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkillProcess.arguments = ["-f", "firebase.*emulators"]
    try? pkillProcess.run()
    pkillProcess.waitUntilExit()
    
    return (200, makeResult(id: id, result: [
      "success": true,
      "message": "Emulator stop signal sent (may have been started externally)"
    ]))
  }
  
  func handleEmulatorConfigure(id: Any?, arguments: [String: Any]) -> (Int, Data) {
    let host = optionalString("host", from: arguments, default: nil)
    let enable = optionalBool("enable", from: arguments, default: true)
    
    if enable {
      let resolvedHost = host ?? "localhost"
      UserDefaults.standard.set(true, forKey: "firebase_use_emulators")
      UserDefaults.standard.set(resolvedHost, forKey: "firebase_emulator_host")
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "enabled": true,
        "host": resolvedHost,
        "message": "Emulator mode configured. Restart the app (or re-run configure()) for changes to take effect.",
        "note": "Both machines on the LAN should set the same emulator host IP.",
        "defaults": [
          "firebase_use_emulators": true,
          "firebase_emulator_host": resolvedHost
        ]
      ]))
    } else {
      UserDefaults.standard.removeObject(forKey: "firebase_use_emulators")
      UserDefaults.standard.removeObject(forKey: "firebase_emulator_host")
      
      return (200, makeResult(id: id, result: [
        "success": true,
        "enabled": false,
        "message": "Emulator mode disabled. App will use production Firebase on next restart."
      ]))
    }
  }
  
  // MARK: - Emulator Helpers
  
  private func checkPort(host: String, port: Int) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    
    // Set a short timeout
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
  }
  
  private func getLocalIP() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    process.arguments = ["getifaddr", "en0"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "localhost"
    } catch {
      return "localhost"
    }
  }
  
  private func findProjectRoot() -> String {
    // Try common locations
    let candidates = [
      FileManager.default.currentDirectoryPath,
      ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? "",
      Self.findRepoRootFromBuildLocation() ?? ""
    ]
    for candidate in candidates {
      if FileManager.default.fileExists(atPath: candidate + "/Tools/firebase-emulator.sh") {
        return candidate
      }
    }
    // Fallback: find via bundle
    if let bundlePath = Bundle.main.bundlePath as NSString? {
      let buildDir = bundlePath.deletingLastPathComponent
      let projectDir = (buildDir as NSString).deletingLastPathComponent
      if FileManager.default.fileExists(atPath: projectDir + "/Tools/firebase-emulator.sh") {
        return projectDir
      }
    }
    return FileManager.default.currentDirectoryPath
  }
  
  /// Find the repo root from #filePath (compile-time source location)
  /// This file lives at: <repo>/Shared/AgentOrchestration/ToolHandlers/SwarmToolsHandler.swift
  private static func findRepoRootFromBuildLocation() -> String? {
    var url = URL(fileURLWithPath: #filePath)
    // Walk up: SwarmToolsHandler.swift -> ToolHandlers/ -> AgentOrchestration/ -> Shared/ -> <repo root>
    for _ in 0..<4 {
      url = url.deletingLastPathComponent()
    }
    let root = url.path
    if FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Tools")) {
      return root
    }
    return nil
  }
}

