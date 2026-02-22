//
//  VMIsolationTypes.swift
//  KitchenSync
//
//  Standalone types and supporting structures for VMIsolationService.
//  Extracted to reduce file size and improve navigability.
//

import Foundation
@preconcurrency import Virtualization

// MARK: - Execution Environment

/// Where to run a task - from lightest to heaviest isolation
public enum ExecutionEnvironment: String, Codable, Sendable, CaseIterable {
  /// Run on host - fastest, full hardware access, least isolated
  /// Use for: trusted code, ANE inference, GPU compute
  case host = "host"
  
  /// Linux VM - lightweight isolation (~3s boot, ~500MB)
  /// Use for: git, compilers, scripts, untrusted analysis
  case linux = "linux"
  
  /// macOS VM - full isolation (~30s boot, ~20GB)
  /// Use for: Xcode builds, codesigning, Apple-specific tools
  case macos = "macos"
  
  var displayName: String {
    switch self {
    case .host: "Host Process"
    case .linux: "Linux VM"
    case .macos: "macOS VM"
    }
  }
  
  var icon: String {
    switch self {
    case .host: "laptopcomputer"
    case .linux: "server.rack"
    case .macos: "desktopcomputer"
    }
  }
  
  /// Typical boot time in seconds
  var typicalBootTime: TimeInterval {
    switch self {
    case .host: 0
    case .linux: 3
    case .macos: 30
    }
  }
  
  /// Minimum disk space needed in GB
  var minimumDiskGB: Int {
    switch self {
    case .host: 0
    case .linux: 1
    case .macos: 20
    }
  }
  
  /// Whether this environment can access ANE
  var hasANEAccess: Bool { self == .host }
  
  /// Whether this environment can access full GPU
  var hasFullGPUAccess: Bool { self == .host }
  
  /// Whether this environment can run Xcode
  var canRunXcode: Bool { self == .macos || self == .host }
  
  /// Whether this environment can do codesigning
  var canCodesign: Bool { self == .macos || self == .host }
}

// MARK: - VM Capability Tiers

/// Defines what capabilities a VM is allowed to have
enum VMCapabilityTier: String, Sendable, CaseIterable {
  /// Read-only filesystem access, no network, no secrets
  case readOnlyAnalysis = "read-only"
  
  /// Write access to workspace, no network, limited secrets
  case writeAction = "write"
  
  /// Network access allowed, full secrets, highest isolation
  case networked = "networked"
  
  /// Compile/build workloads, high CPU priority, no network
  case compileFarm = "compile"
  
  var hasNetworkAccess: Bool {
    self == .networked
  }
  
  var hasWriteAccess: Bool {
    self != .readOnlyAnalysis
  }
  
  var hasSecretAccess: Bool {
    self == .networked || self == .writeAction
  }
  
  var description: String {
    switch self {
    case .readOnlyAnalysis: "Read-Only Analysis"
    case .writeAction: "Write Action"
    case .networked: "Networked"
    case .compileFarm: "Compile Farm"
    }
  }
  
  /// Recommended execution environment for this tier
  var recommendedEnvironment: ExecutionEnvironment {
    switch self {
    case .readOnlyAnalysis: .linux  // Fast, disposable
    case .writeAction: .linux       // Still lightweight
    case .networked: .linux         // Linux handles network fine
    case .compileFarm: .linux       // Unless Xcode needed, then .macos
    }
  }
}

// MARK: - Tool Dependencies

struct VMToolDependency: Sendable, Hashable {
  let tool: String
  let brewPackage: String
  let purpose: String
}

// MARK: - VM Resource Limits

/// Resource constraints for a VM instance
struct VMResourceLimits: Sendable {
  let cpuCores: Int
  let memoryGB: Int
  let diskGB: Int
  let timeoutSeconds: Int
  let gpuAccess: Bool
  
  static let minimal = VMResourceLimits(
    cpuCores: 2,
    memoryGB: 2,
    diskGB: 2,
    timeoutSeconds: 300,
    gpuAccess: false
  )
  
  static let standard = VMResourceLimits(
    cpuCores: 4,
    memoryGB: 4,
    diskGB: 8,
    timeoutSeconds: 600,
    gpuAccess: false
  )
  
  static let linux = VMResourceLimits(
    cpuCores: 4,
    memoryGB: 3,
    diskGB: 4,
    timeoutSeconds: 300,
    gpuAccess: false
  )
  
  static let compileFarm = VMResourceLimits(
    cpuCores: 8,
    memoryGB: 8,
    diskGB: 16,
    timeoutSeconds: 1800,
    gpuAccess: false
  )
  
  static let macOSBuild = VMResourceLimits(
    cpuCores: 8,
    memoryGB: 16,
    diskGB: 32,
    timeoutSeconds: 3600,
    gpuAccess: true
  )
}

// MARK: - Console State (Thread-Safe)

final class VMConsoleState: @unchecked Sendable {
  let queue = DispatchQueue(label: "vm.console.reader", attributes: .concurrent)
  private var buffer: String = ""
  private let lock = NSLock()
  let maxBufferBytes = 64 * 1024
  private var shouldStop = false
  private var bytesRead: Int64 = 0
  private var lastOutputAt: Date?

  func append(_ text: String) {
    lock.lock()
    buffer.append(text)
    lastOutputAt = Date()
    if buffer.utf8.count > maxBufferBytes {
      let tail = buffer.suffix(maxBufferBytes)
      buffer = String(tail)
    }
    lock.unlock()
  }

  func recordBytes(_ count: Int) {
    lock.lock()
    bytesRead += Int64(count)
    lock.unlock()
  }

  func totalBytesRead() -> Int64 {
    lock.lock()
    let value = bytesRead
    lock.unlock()
    return value
  }

  func drain() -> String? {
    lock.lock()
    if buffer.isEmpty {
      lock.unlock()
      return nil
    }
    let chunk = buffer
    buffer = ""
    lock.unlock()
    return chunk
  }

  func clear() {
    lock.lock()
    buffer = ""
    lastOutputAt = nil
    lock.unlock()
  }

  func lastOutputTimestamp() -> Date? {
    lock.lock()
    let value = lastOutputAt
    lock.unlock()
    return value
  }

  func markStart() {
    lock.lock()
    shouldStop = false
    lock.unlock()
  }

  func markStop() {
    lock.lock()
    shouldStop = true
    lock.unlock()
  }

  func isStopping() -> Bool {
    lock.lock()
    let value = shouldStop
    lock.unlock()
    return value
  }
}

enum VMConsoleReader {
  /// Strip ANSI escape codes from console output
  /// Removes color codes, cursor movement, and other terminal control sequences
  static func stripANSIEscapeCodes(_ text: String) -> String {
    // Pattern matches:
    // - ESC[ followed by any sequence of digits, semicolons, and ending in a letter (CSI sequences)
    // - ESC] followed by anything up to BEL or ST (OSC sequences)
    // - Other ESC sequences
    let ansiPattern = "\\x1B(?:\\[[0-9;]*[a-zA-Z]|\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)|[=>\\(\\)][0-9A-Za-z]?)"
    guard let regex = try? NSRegularExpression(pattern: ansiPattern, options: []) else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
  }
  
  static func start(state: VMConsoleState, fd: Int32) {
    state.markStart()
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    
    state.queue.async {
      // vmLog("Starting read loop on fd \(fd)")
      var buffer = [UInt8](repeating: 0, count: 4096)
      
      while !state.isStopping() {
        let count = read(fd, &buffer, buffer.count)
        
        if count > 0 {
          let data = Data(bytes: buffer, count: count)
          if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            // Strip ANSI escape codes before appending
            let cleanText = stripANSIEscapeCodes(text)
            state.append(cleanText)
          }
          state.recordBytes(count)
        } else if count == 0 {
          // EOF
          break
        } else {
          let err = errno
          if err == EAGAIN || err == EWOULDBLOCK {
            usleep(10_000)
            continue
          }
          print("[ConsoleReader] Error reading fd \(fd): \(err)")
          break
        }
      }
    }
  }

  static func stop(state: VMConsoleState) {
    state.markStop()
    state.clear()
  }
}

// MARK: - macOS VM Configuration

/// Configuration for full macOS VMs
struct MacOSVMConfig: Sendable {
  /// Path to the restore image (.ipsw) or nil to download latest
  let restoreImagePath: URL?
  
  /// Path to the VM bundle directory
  let vmBundlePath: URL
  
  /// Hardware model identifier
  let hardwareModelPath: URL
  
  /// Machine identifier for this VM
  let machineIdentifierPath: URL
  
  /// Resources allocated to this VM
  let resources: VMResourceLimits
  
  /// Auxiliary storage path (for macOS boot data)
  let auxiliaryStoragePath: URL
  
  /// Main disk image path
  let diskImagePath: URL
}

// MARK: - VM Task

/// A task to be executed in an isolated environment
struct VMTask: Sendable, Identifiable {
  let id: UUID
  let capability: VMCapabilityTier
  let environment: ExecutionEnvironment
  let command: String
  let workingDirectory: String?
  let environmentVariables: [String: String]
  let resources: VMResourceLimits
  let snapshotId: String?  // Restore to this snapshot after completion
  
  /// Convenience: create a task that auto-selects the best environment
  init(
    id: UUID = UUID(),
    capability: VMCapabilityTier,
    command: String,
    workingDirectory: String? = nil,
    environmentVariables: [String: String] = [:],
    requiresXcode: Bool = false,
    requiresCodesign: Bool = false,
    snapshotId: String? = nil
  ) {
    self.id = id
    self.capability = capability
    self.command = command
    self.workingDirectory = workingDirectory
    self.environmentVariables = environmentVariables
    self.snapshotId = snapshotId
    
    // Auto-select environment based on requirements
    if requiresXcode || requiresCodesign {
      self.environment = .macos
      self.resources = .macOSBuild
    } else {
      self.environment = capability.recommendedEnvironment
      self.resources = capability == .compileFarm ? .compileFarm : .linux
    }
  }
  
  /// Explicit environment selection
  init(
    id: UUID = UUID(),
    capability: VMCapabilityTier,
    environment: ExecutionEnvironment,
    command: String,
    workingDirectory: String? = nil,
    environmentVariables: [String: String] = [:],
    resources: VMResourceLimits,
    snapshotId: String? = nil
  ) {
    self.id = id
    self.capability = capability
    self.environment = environment
    self.command = command
    self.workingDirectory = workingDirectory
    self.environmentVariables = environmentVariables
    self.resources = resources
    self.snapshotId = snapshotId
  }
}

// MARK: - VM Task Result

/// Result of executing a task in a VM
struct VMTaskResult: Sendable {
  let taskId: UUID
  let environment: ExecutionEnvironment
  let exitCode: Int32
  let stdout: String
  let stderr: String
  let executionTime: TimeInterval
  let bootTime: TimeInterval  // Time to start VM (0 for host)
  let resourceUsage: VMResourceUsage
}

/// Resource usage metrics from VM execution
struct VMResourceUsage: Sendable {
  let cpuTimeSeconds: Double
  let peakMemoryMB: Int
  let diskWritesMB: Int
  let networkBytesSent: Int
  let networkBytesReceived: Int
}

// MARK: - VM Pool State

/// Represents a pool of VMs for a specific configuration
struct VMPool: Sendable {
  let tier: VMCapabilityTier
  let environment: ExecutionEnvironment
  var availableCount: Int
  var busyCount: Int
  var maxCount: Int
  
  var totalCount: Int { availableCount + busyCount }
  var utilizationPercent: Double {
    guard totalCount > 0 else { return 0 }
    return Double(busyCount) / Double(totalCount) * 100
  }
}

// MARK: - VM Delegate

/// Delegate to capture VM state changes and errors
final class VMDelegate: NSObject, VZVirtualMachineDelegate {
  private let onStop: ((Error?) -> Void)?

  init(onStop: ((Error?) -> Void)? = nil) {
    self.onStop = onStop
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    print("[VM Delegate] VM stopped with error: \(error)")
    let nsError = error as NSError
    print("[VM Delegate] Error domain: \(nsError.domain), code: \(nsError.code)")
    for (key, value) in nsError.userInfo {
      print("[VM Delegate] UserInfo[\(key)]: \(value)")
    }
    onStop?(error)
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    print("[VM Delegate] Guest did stop")
    onStop?(nil)
  }
}

// MARK: - Errors

enum VMError: LocalizedError {
  case notInitialized
  case virtualizationNotAvailable
  case linuxNotConfigured
  case macOSRestoreImageNotFound
  case poolExhausted(VMCapabilityTier)
  case taskTimeout(UUID)
  case commandTimeout(Int)
  case snapshotNotFound(String)
  case vmCreationFailed(String)
  case vmAlreadyRunning
  case vmNotRunning
  case bootstrapFailed(String)
  
  var errorDescription: String? {
    switch self {
    case .notInitialized:
      "VM Isolation Service is not initialized"
    case .virtualizationNotAvailable:
      "Virtualization.framework is not available on this system"
    case .linuxNotConfigured:
      "Linux VM not configured. Add kernel and rootfs to VMs/linux/"
    case .macOSRestoreImageNotFound:
      "macOS restore image not found. Use downloadMacOSRestoreImage() to fetch one."
    case .poolExhausted(let tier):
      "No available VMs in \(tier.description) pool"
    case .taskTimeout(let id):
      "Task \(id) exceeded time limit"
    case .commandTimeout(let seconds):
      "VM command timed out after \(seconds)s"
    case .snapshotNotFound(let name):
      "Snapshot '\(name)' not found"
    case .vmCreationFailed(let reason):
      "Failed to create VM: \(reason)"
    case .vmAlreadyRunning:
      "A Linux VM is already running"
    case .vmNotRunning:
      "No Linux VM is currently running"
    case .bootstrapFailed(let reason):
      "VM bootstrap failed: \(reason)"
    }
  }
}
