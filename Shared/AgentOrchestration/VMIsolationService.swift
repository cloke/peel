//
//  VMIsolationService.swift
//  KitchenSync
//
//  Created on 1/16/26.
//
//  Provides VM-based isolation for agent task execution using Apple's Hypervisor.framework.
//  This enables running untrusted or experimental agent code in isolated environments.
//
//  Architecture Overview:
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │                         Host (Kitchen Sync)                          │
//  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                  │
//  │  │ AgentManager │  │ VMIsolation │  │ TaskScheduler│                  │
//  │  │             │──│   Service   │──│             │                  │
//  │  └─────────────┘  └──────┬──────┘  └─────────────┘                  │
//  │                          │                                           │
//  │    Execution Tiers (lightest → heaviest):                           │
//  │    ┌────────────────────────────────────────────────────────┐       │
//  │    │ 1. Host Process │ 2. Linux VM │ 3. macOS VM            │       │
//  │    │   (trusted,     │  (light,    │  (full isolation,      │       │
//  │    │    ANE/GPU)     │   fast)     │   Xcode/signing)       │       │
//  │    └────────────────────────────────────────────────────────┘       │
//  │                                                                      │
//  │    VM Pools by Capability:                                          │
//  │    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐               │
//  │    │  Read-Only   │ │    Write     │ │  Networked   │               │
//  │    │  Analysis    │ │   Action     │ │   Agent      │               │
//  │    │  (Linux)     │ │  (Linux)     │ │ (Linux/mac)  │               │
//  │    └──────────────┘ └──────────────┘ └──────────────┘               │
//  └─────────────────────────────────────────────────────────────────────┘
//
//  Key Design Decisions:
//  - Linux VMs for most tasks (fast boot ~3s, small footprint ~500MB)
//  - macOS VMs only when needed (Xcode, codesigning, Apple frameworks)
//  - Host process for trusted ops that need ANE/GPU (not available in VMs)
//  - Snapshot-rewind for reproducibility
//

#if os(macOS)

import Foundation
import Darwin
@preconcurrency import Virtualization

// MARK: - Execution Environment

/// Where to run a task - from lightest to heaviest isolation
enum ExecutionEnvironment: String, Sendable, CaseIterable {
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

private final class VMConsoleState: @unchecked Sendable {
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

private enum VMConsoleReader {
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

// MARK: - VM Isolation Service

/// Service for managing isolated VM execution of agent tasks
///
/// This service provides:
/// - VM lifecycle management (create, start, stop, destroy)
/// - Task scheduling across VM pools
/// - Snapshot management for reproducibility
/// - Resource monitoring and limits
/// - Automatic environment selection (host vs Linux VM vs macOS VM)
///
/// Usage:
/// ```swift
/// let service = VMIsolationService()
/// await service.initialize()
///
/// // Auto-selects Linux VM (fastest for this task)
/// let task = VMTask(
///   capability: .readOnlyAnalysis,
///   command: "git log --oneline -10"
/// )
///
/// // Forces macOS VM (needs Xcode)
/// let buildTask = VMTask(
///   capability: .compileFarm,
///   command: "xcodebuild -scheme MyApp build",
///   requiresXcode: true
/// )
///
/// let result = try await service.execute(task)
/// ```
@MainActor
@Observable
final class VMIsolationService {
  
  // MARK: - State
  
  /// Whether the service is initialized and ready
  private(set) var isInitialized = false
  
  /// Whether Virtualization.framework is available
  private(set) var isVirtualizationAvailable = false
  
  /// Whether Linux VM support is ready
  private(set) var isLinuxReady = false
  
  /// Whether macOS VM support is ready (restore image available)
  private(set) var isMacOSReady = false
  
  /// Path to macOS restore image, if available
  private(set) var macOSRestoreImagePath: URL?
  
  /// Current VM pools by capability tier and environment
  private(set) var pools: [String: VMPool] = [:]  // Key: "tier:environment"
  
  /// Active tasks being executed
  private(set) var activeTasks: [UUID: VMTask] = [:]
  
  /// Task history for auditing
  private(set) var taskHistory: [VMTaskResult] = []
  
  /// Disk snapshots available for VMs
  private(set) var snapshots: [String: Date] = [:]
  
  /// Status message for UI
  private(set) var statusMessage: String = "Not initialized"
  
  /// Currently running Linux VM (if any)
  private(set) var runningLinuxVM: VZVirtualMachine?
  private(set) var runningMacOSVM: VZVirtualMachine?
  
  /// Whether a Linux VM is currently running
  var isLinuxVMRunning: Bool { runningLinuxVM?.state == .running }
  var isMacOSVMRunning: Bool { runningMacOSVM?.state == .running }
  
  /// Console output from the running VM
  private(set) var consoleOutput: String = ""
  
  /// VM delegate (kept alive while VM is running)
  private var vmDelegate: VMDelegate?
  private var macOSVMDelegate: VMDelegate?
  private var macOSInstaller: VZMacOSInstaller?
  private(set) var isMacOSInstalling = false

  /// Console pipes (kept alive while VM is running)
  private var consoleInputPipe: Pipe?
  private var consoleOutputPipe: Pipe?
  private var serialInputPipe: Pipe?
  private var serialOutputPipe: Pipe?
  private var consoleReadTask: Task<Void, Never>?
  private var consoleFlushTimer: DispatchSourceTimer?
  private let consoleState = VMConsoleState()
  private var lastConsoleInactivityLogAt: Date?
  private let consoleMaxOutputChars = 200_000

  /// Throttle console output to avoid UI hangs
  private let consoleFlushInterval: TimeInterval = 0.25
  private let consoleFlushByteThreshold = 4096
  private(set) var isConsoleOutputEnabled = false
  
  // MARK: - Configuration
  
  /// Base path for VM disk images and configs
  private let vmBasePath: URL
  
  /// Maximum tasks to keep in history
  private let maxHistoryCount = 100

  /// Debug toggles (keep minimal while stabilizing VM boot)
  private let attachLinuxDiskImage = false
  private let attachLinuxNetwork = true
  private let attachMemoryBalloon = false
  private let attachMacOSNetwork = true
  private let isVerboseVMLogging = true

  // MARK: - Dependencies

  private func requiredDependencies() -> [VMToolDependency] {
    let linuxDir = linuxVMDirectory
    let initramfsPath = linuxDir.appendingPathComponent("initramfs")

    if FileManager.default.fileExists(atPath: initramfsPath.path), isXZFile(at: initramfsPath.path) {
      return [VMToolDependency(tool: "xz", brewPackage: "xz", purpose: "Decompress Linux initramfs (XZ)")]
    }

    return []
  }
  
  // MARK: - Initialization
  
  init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first 
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    self.vmBasePath = appSupport.appendingPathComponent("KitchenSync/VMs", isDirectory: true)
  }
  
  /// Initialize the service and check for Virtualization.framework support
  func initialize() async {
    statusMessage = "Checking virtualization support..."
    
    // Check if running on Apple Silicon (required for Virtualization.framework)
    isVirtualizationAvailable = checkVirtualizationSupport()
    
    if isVirtualizationAvailable {
      // Create VM storage directory
      try? FileManager.default.createDirectory(at: vmBasePath, withIntermediateDirectories: true)
      
      // Check for Linux VM support
      await checkLinuxVMSupport()

      // Auto-provision if missing or outdated/mismatched
      if !isLinuxReady {
        print("[VM Init] Linux VM not ready, attempting auto-setup...")
        do {
            try await setupLinuxVM()
        } catch {
            print("[VM Init] Auto-setup failed: \(error)")
            // Continue, statusMessage will reflect the error if set in setupLinuxVM
        }
      }
      
      // Check for macOS VM support
      await checkMacOSVMSupport()
      
      // Initialize pools for each tier
      initializePools()
      
      // Load existing snapshots
      await loadSnapshots()
      
      statusMessage = buildStatusMessage()
    } else {
      statusMessage = "Virtualization not available on this system"
    }
    
    isInitialized = true
  }
  
  private func buildStatusMessage() -> String {
    var parts: [String] = []
    if isLinuxReady {
      parts.append("Linux VMs ready")
    }
    if isMacOSReady {
      parts.append("macOS VMs ready")
    }
    if parts.isEmpty {
      return "No VM images configured"
    }
    return parts.joined(separator: " • ")
  }
  
  private func initializePools() {
    // Linux pools (lighter weight, more instances)
    for tier in VMCapabilityTier.allCases {
      let key = "\(tier.rawValue):linux"
      pools[key] = VMPool(tier: tier, environment: .linux, availableCount: 0, busyCount: 0, maxCount: 4)
    }
    
    // macOS pools (heavier, fewer instances)
    pools["compile:macos"] = VMPool(tier: .compileFarm, environment: .macos, availableCount: 0, busyCount: 0, maxCount: 2)
    pools["networked:macos"] = VMPool(tier: .networked, environment: .macos, availableCount: 0, busyCount: 0, maxCount: 2)
  }
  
  // MARK: - VM Support Checks
  
  /// Get the path where Linux VM files should be stored
  var linuxVMDirectory: URL {
    vmBasePath.appendingPathComponent("linux", isDirectory: true)
  }
  
  /// Get the path where macOS VM files should be stored
  var macOSVMDirectory: URL {
    vmBasePath.appendingPathComponent("macos", isDirectory: true)
  }

  private var macOSVMBundlePath: URL {
    macOSVMDirectory.appendingPathComponent("Default.bundle", isDirectory: true)
  }

  private var macOSHardwareModelPath: URL {
    macOSVMBundlePath.appendingPathComponent("HardwareModel.bin")
  }

  private var macOSMachineIdentifierPath: URL {
    macOSVMBundlePath.appendingPathComponent("MachineIdentifier.bin")
  }

  private var macOSAuxiliaryStoragePath: URL {
    macOSVMBundlePath.appendingPathComponent("AuxiliaryStorage.bin")
  }

  private var macOSDiskImagePath: URL {
    macOSVMBundlePath.appendingPathComponent("Disk.img")
  }

  private var macOSInstallMarkerPath: URL {
    macOSVMBundlePath.appendingPathComponent(".installed")
  }

  var isMacOSVMInstalled: Bool {
    FileManager.default.fileExists(atPath: macOSInstallMarkerPath.path)
  }
  
  private func checkLinuxVMSupport() async {
    // Check if we have a Linux kernel and initramfs
    let linuxDir = linuxVMDirectory
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let initramfsPath = linuxDir.appendingPathComponent("initramfs")
    let distroTagPath = linuxDir.appendingPathComponent(".distro")
    let targetTag = "alpine-3.21-virt"

    // Validate Distro Tag
    let currentTag = (try? String(contentsOf: distroTagPath, encoding: .utf8)) ?? ""
    if currentTag != targetTag {
      print("[VM Check] Distro tag mismatch. Found: '\(currentTag)', Expected: '\(targetTag)'. Marking as not ready.")
      isLinuxReady = false
      return
    }
    
    let kernelExists = FileManager.default.fileExists(atPath: kernelPath.path)
    let initramfsExists = FileManager.default.fileExists(atPath: initramfsPath.path)
    let initramfsIsGzip = initramfsExists && isGzipFile(at: initramfsPath.path)
    let initramfsIsXZ = initramfsExists && isXZFile(at: initramfsPath.path)
    let initramfsIsCpio = initramfsExists && isCpioFile(at: initramfsPath.path)
    
    let kernelIsPE = kernelExists && isPEKernel(at: kernelPath.path)
    isLinuxReady = kernelExists && initramfsExists && initramfsIsCpio
    
    if kernelIsPE {
      print("[VM Check] Kernel appears to be EFI/PE (MZ). Marking as not ready to force fixup.")
      isLinuxReady = false
    }
    
    // Log what we found for debugging
    if isLinuxReady {
      if let kernelAttrs = try? FileManager.default.attributesOfItem(atPath: kernelPath.path),
         let initramfsAttrs = try? FileManager.default.attributesOfItem(atPath: initramfsPath.path) {
        let kernelSize = kernelAttrs[.size] as? Int ?? 0
        let initramfsSize = initramfsAttrs[.size] as? Int ?? 0
        print("Linux VM files found - kernel: \(kernelSize) bytes, initramfs: \(initramfsSize) bytes")
      }
    } else {
      if initramfsIsXZ {
        print("Linux VM initramfs is XZ-compressed (needs conversion). Re-run setup.")
      } else if initramfsIsGzip {
        print("Linux VM initramfs is gzip-compressed (needs conversion). Re-run setup.")
      }
      if kernelIsPE {
        print("Linux VM kernel appears to be EFI/PE (MZ). This may still boot, but is a common failure source.")
      }
    }
  }
  
  /// Reset Linux VM by deleting all files and re-downloading
  func resetLinuxVM() async throws {
    statusMessage = "Resetting Linux VM..."
    
    // Stop any running VM first
    if runningLinuxVM != nil {
      try await stopLinuxVM()
    }
    
    // Delete existing files
    let linuxDir = linuxVMDirectory
    if FileManager.default.fileExists(atPath: linuxDir.path) {
      try FileManager.default.removeItem(at: linuxDir)
    }
    
    isLinuxReady = false
    
    // Re-setup
    try await setupLinuxVM()
  }
  
  /// Download and set up a Linux VM
  /// Downloads Alpine Linux kernel and initramfs (arm64) for VZLinuxBootLoader compatibility
  func setupLinuxVM() async throws {
    statusMessage = "Setting up Linux VM environment..."
    
    let linuxDir = linuxVMDirectory
    try FileManager.default.createDirectory(at: linuxDir, withIntermediateDirectories: true)
    
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let initrdPath = linuxDir.appendingPathComponent("initramfs")
    let distroTagPath = linuxDir.appendingPathComponent(".distro")
    let targetTag = "alpine-3.21-virt"
    
    // WARNING: Alpine vmlinuz is an EFI/PE executable. VZLinuxBootLoader requires a raw Image.
    // 'setupLinuxVM' calls 'extractEmbeddedKernel' to fix this.
    // DO NOT revert to using the downloaded kernel directly without this check.
    
    // Check if we already have the correct files
    let currentTag = (try? String(contentsOf: distroTagPath, encoding: .utf8)) ?? ""
    let filesExist = FileManager.default.fileExists(atPath: kernelPath.path) &&
                     FileManager.default.fileExists(atPath: initrdPath.path)
    
    if currentTag == targetTag && filesExist {
      print("[VM Setup] Files already present for \(targetTag). Skipping download.")
    } else {
      // Cleanup old files if tag mismatch
      if currentTag != targetTag {
        print("[VM Setup] Distro changed (was: \(currentTag)), cleaning up...")
        try? FileManager.default.removeItem(at: kernelPath)
        try? FileManager.default.removeItem(at: initrdPath)
        try? FileManager.default.removeItem(at: linuxDir.appendingPathComponent("initramfs.raw"))
      }
      
      statusMessage = "Downloading Alpine Linux..."
      // Alpine is lightweight and uses a standard uncompressed/gzip kernel format that works well with VZ
      let base = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot"
      let kernelURL = URL(string: "\(base)/vmlinuz-virt")!
      let initrdURL = URL(string: "\(base)/initramfs-virt")!
        
      let kData = try await downloadFirstAvailable(urls: [kernelURL], minimumBytes: 5_000_000, label: "Alpine Kernel")
      let iData = try await downloadFirstAvailable(urls: [initrdURL], minimumBytes: 2_000_000, label: "Alpine Initramfs")
      
      try kData.write(to: kernelPath)
      try iData.write(to: initrdPath)
      
      try targetTag.write(to: distroTagPath, atomically: true, encoding: .utf8)
    }

    print("[VM Setup] Alpine kernel/initramfs ready")

    if isXZFile(at: initrdPath.path) {
      // Convert XZ to raw cpio (Virtualization.framework initrd handling is finicky with XZ)
      statusMessage = "Decompressing initramfs (XZ → raw)..."
      print("[VM Setup] Decompressing initramfs (XZ → raw)")
      let initrdRawPath = linuxDir.appendingPathComponent("initramfs.raw")
      let xzResult = try await decompressXZ(inputPath: initrdPath.path, outputPath: initrdRawPath.path)
      guard xzResult else {
        throw VMError.vmCreationFailed("Failed to decompress XZ initramfs. Ensure 'xz' is installed.")
      }
      guard isCpioFile(at: initrdRawPath.path) else {
        throw VMError.vmCreationFailed("Initramfs conversion failed. Output is not CPIO.")
      }
      try? FileManager.default.removeItem(at: initrdPath)
      try FileManager.default.moveItem(at: initrdRawPath, to: initrdPath)
      print("[VM Setup] Initramfs converted to raw CPIO format.")
    }

    if isGzipFile(at: initrdPath.path) {
      statusMessage = "Decompressing initramfs (gzip → raw)..."
      print("[VM Setup] Decompressing initramfs (gzip → raw)")
      let initrdRawPath = linuxDir.appendingPathComponent("initramfs.raw")
      let gzipResult = try await decompressGzip(inputPath: initrdPath.path, outputPath: initrdRawPath.path)
      guard gzipResult else {
        throw VMError.vmCreationFailed("Failed to decompress gzip initramfs.")
      }
      guard isCpioFile(at: initrdRawPath.path) else {
        throw VMError.vmCreationFailed("Initramfs conversion failed. Output is not CPIO.")
      }
      try? FileManager.default.removeItem(at: initrdPath)
      try FileManager.default.moveItem(at: initrdRawPath, to: initrdPath)
      print("[VM Setup] Initramfs converted to raw CPIO format.")
    }

    let kernelIsPE = isPEKernel(at: kernelPath.path)
    if kernelIsPE {
      print("[VM Setup] Kernel appears to be EFI/PE (MZ). Attempting to extract raw Image...")
      let rawKernelPath = linuxDir.appendingPathComponent("vmlinuz.raw")
      if try await extractEmbeddedKernel(inputPath: kernelPath.path, outputPath: rawKernelPath.path) {
        try? FileManager.default.removeItem(at: kernelPath)
        try FileManager.default.moveItem(at: rawKernelPath, to: kernelPath)
        print("[VM Setup] Replaced EFI kernel with raw Image.")
      } else {
        print("[VM Setup] Failed to extract raw kernel. This may fail to boot.")
      }
    }
    isLinuxReady = isCpioFile(at: initrdPath.path)
    statusMessage = "Linux VM ready"
  }
  
  private func extractEmbeddedKernel(inputPath: String, outputPath: String) async throws -> Bool {
    print("[VM Setup] Checking for embedded gzip kernel in \(inputPath)...")
    let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
    // Search for gzip magic: 1f 8b 08. Scan first 64KB for speed.
    let scanLimit = min(data.count, 65536)
    let scanData = data[0..<scanLimit]
    guard let range = scanData.range(of: Data([0x1f, 0x8b, 0x08])) else {
      print("[VM Setup] No gzip header found in kernel header.")
      return false
    }
    print("[VM Setup] Found embedded gzip stream at offset \(range.lowerBound). Extracting...")
    
    let tempGz = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kernel_embedded_\(UUID().uuidString).gz")
    try data[range.lowerBound...].write(to: tempGz)
    
    // Decompress
    // Note: gunzip may return exit code 2 if there is trailing garbage (the rest of the PE file),
    // which is expected here. We check the output file size instead.
    let gzipPath = "/usr/bin/gzip"
    _ = try await runProcess(gzipPath, arguments: ["-d", "-c", tempGz.path], outputPath: outputPath)
    
    // Validation
    let outAttrs = try? FileManager.default.attributesOfItem(atPath: outputPath)
    let size = outAttrs?[.size] as? Int64 ?? 0
    let valid = size > 2_000_000 // Kernel should be > 2MB usually
    
    try? FileManager.default.removeItem(at: tempGz)
    
    if valid {
      print("[VM Setup] Successfully extracted raw kernel (\(size) bytes).")
    } else {
      print("[VM Setup] Extraction failed or result too small.")
    }
    return valid
  }
  
  private func checkMacOSVMSupport() async {
    // Check for existing restore image
    let macosDir = vmBasePath.appendingPathComponent("macos", isDirectory: true)
    let restoreImagePath = macosDir.appendingPathComponent("RestoreImage.ipsw")
    
    if FileManager.default.fileExists(atPath: restoreImagePath.path) {
      self.macOSRestoreImagePath = restoreImagePath
      isMacOSReady = true
    } else {
      // Could check for system restore image location or offer to download
      isMacOSReady = false
    }
  }

  @available(macOS 12.0, *)
  private func loadMacOSRestoreImage() async throws -> VZMacOSRestoreImage {
    guard let restoreImagePath = macOSRestoreImagePath else {
      throw VMError.macOSRestoreImageNotFound
    }
    return try await VZMacOSRestoreImage.image(from: restoreImagePath)
  }

  @available(macOS 12.0, *)
  private func loadOrCreateMacOSHardwareModel(from restoreImage: VZMacOSRestoreImage) throws -> VZMacHardwareModel {
    if FileManager.default.fileExists(atPath: macOSHardwareModelPath.path),
       let data = try? Data(contentsOf: macOSHardwareModelPath),
       let model = VZMacHardwareModel(dataRepresentation: data) {
      return model
    }

    guard let configuration = restoreImage.mostFeaturefulSupportedConfiguration else {
      throw VMError.vmCreationFailed("No supported macOS hardware configuration for this host")
    }
    let model = configuration.hardwareModel
    try model.dataRepresentation.write(to: macOSHardwareModelPath)
    return model
  }

  private func loadOrCreateMacOSMachineIdentifier() throws -> VZMacMachineIdentifier {
    if FileManager.default.fileExists(atPath: macOSMachineIdentifierPath.path),
       let data = try? Data(contentsOf: macOSMachineIdentifierPath),
       let identifier = VZMacMachineIdentifier(dataRepresentation: data) {
      return identifier
    }

    let identifier = VZMacMachineIdentifier()
    try identifier.dataRepresentation.write(to: macOSMachineIdentifierPath)
    return identifier
  }

  @available(macOS 12.0, *)
  private func loadOrCreateMacOSAuxiliaryStorage(hardwareModel: VZMacHardwareModel) throws -> VZMacAuxiliaryStorage {
    if FileManager.default.fileExists(atPath: macOSAuxiliaryStoragePath.path) {
      return VZMacAuxiliaryStorage(url: macOSAuxiliaryStoragePath)
    }

    return try VZMacAuxiliaryStorage(
      creatingStorageAt: macOSAuxiliaryStoragePath,
      hardwareModel: hardwareModel,
      options: []
    )
  }

  private func ensureMacOSDiskImage(sizeGB: Int) throws -> URL {
    if !FileManager.default.fileExists(atPath: macOSDiskImagePath.path) {
      FileManager.default.createFile(atPath: macOSDiskImagePath.path, contents: nil)
      let handle = try FileHandle(forWritingTo: macOSDiskImagePath)
      let diskSize = UInt64(max(20, sizeGB)) * 1024 * 1024 * 1024
      try handle.truncate(atOffset: diskSize)
      try handle.close()
      print("[VM] Created macOS disk image: \(macOSDiskImagePath.path) (\(max(20, sizeGB)) GB)")
    }
    return macOSDiskImagePath
  }

  @available(macOS 12.0, *)
  private func createMacOSVMConfiguration(
    restoreImage: VZMacOSRestoreImage,
    resources: VMResourceLimits
  ) throws -> VZVirtualMachineConfiguration {
    try FileManager.default.createDirectory(at: macOSVMBundlePath, withIntermediateDirectories: true)

    let hardwareModel = try loadOrCreateMacOSHardwareModel(from: restoreImage)
    let machineIdentifier = try loadOrCreateMacOSMachineIdentifier()
    let auxiliaryStorage = try loadOrCreateMacOSAuxiliaryStorage(hardwareModel: hardwareModel)

    let config = VZVirtualMachineConfiguration()
    config.bootLoader = VZMacOSBootLoader()

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hardwareModel
    platform.machineIdentifier = machineIdentifier
    platform.auxiliaryStorage = auxiliaryStorage
    config.platform = platform

    config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, resources.cpuCores)
    let memoryBytes = UInt64(resources.memoryGB) * 1024 * 1024 * 1024
    config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, memoryBytes)

    let diskURL = try ensureMacOSDiskImage(sizeGB: resources.diskGB)
    let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
    let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
    config.storageDevices = [blockDevice]

    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 160)]
    config.graphicsDevices = [graphics]

    if #available(macOS 13.0, *) {
      config.keyboards = [VZUSBKeyboardConfiguration()]
      config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    if attachMacOSNetwork {
      let networkDevice = VZVirtioNetworkDeviceConfiguration()
      networkDevice.attachment = VZNATNetworkDeviceAttachment()
      config.networkDevices = [networkDevice]
    }

    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    try config.validate()
    return config
  }
  
  // MARK: - VM Lifecycle
  
  private func createMinimalLinuxVMConfiguration() throws -> VZVirtualMachineConfiguration {
    let linuxDir = linuxVMDirectory
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let initramfsPath = linuxDir.appendingPathComponent("initramfs")
    
    vmDebug("Creating minimal Linux VM configuration...")
    vmDebug("Kernel path: \(kernelPath.path)")
    vmDebug("Initramfs path: \(initramfsPath.path)")
    
    guard FileManager.default.fileExists(atPath: kernelPath.path) else {
      throw VMError.vmCreationFailed("Kernel not found at \(kernelPath.path)")
    }
    guard FileManager.default.fileExists(atPath: initramfsPath.path) else {
      throw VMError.vmCreationFailed("Initramfs not found at \(initramfsPath.path)")
    }
    if isXZFile(at: initramfsPath.path) {
      throw VMError.vmCreationFailed("Initramfs is XZ-compressed. Re-run Setup Linux VM.")
    }
    
    let bootLoader = VZLinuxBootLoader(kernelURL: kernelPath)
    bootLoader.initialRamdiskURL = initramfsPath
    // console=hvc0/hvc1 -> Virtio consoles (primary for Apple VZ)
    // console=ttyAMA0   -> PL011 (ARM default - valid if we have PL011, ignored otherwise)
    //
    // TODO: The current Alpine boot fails at "Mounting boot media".
    // Use netboot repo + modloop to provide rootfs for diskless boot.
    let alpineRepo = "http://dl-cdn.alpinelinux.org/alpine/v3.21/main"
    let modloop = "http://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot/modloop-virt"
    bootLoader.commandLine = "console=ttyS0 console=ttyAMA0 console=hvc0 console=hvc1 earlycon loglevel=7 debug alpine_repo=\(alpineRepo) modloop=\(modloop)"
    vmLog("Boot command line: \(bootLoader.commandLine)")
    
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    
    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = VZGenericMachineIdentifier()
    config.platform = platform
    vmDebug("Platform: Generic (Linux), machineId: \(platform.machineIdentifier.dataRepresentation.base64EncodedString())")
    
    let cpuCount = 2
    config.cpuCount = cpuCount
    config.memorySize = max(2 * 1024 * 1024 * 1024, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    
    // Virtio console device + system console port
    let consoleInput = Pipe()
    let consoleOutput = Pipe()
    let consoleAttachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: consoleInput.fileHandleForReading,
      fileHandleForWriting: consoleOutput.fileHandleForWriting
    )
    if #available(macOS 13.0, *) {
      let consoleDevice = VZVirtioConsoleDeviceConfiguration()
      let consolePort = VZVirtioConsolePortConfiguration()
      consolePort.attachment = consoleAttachment
      consolePort.isConsole = true
      consolePort.name = "console"
      consoleDevice.ports[0] = consolePort
      config.consoleDevices = [consoleDevice]
    } else {
      let serialPortConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
      serialPortConfig.attachment = consoleAttachment
      config.serialPorts = [serialPortConfig]
    }

    // Additional serial port for fallback output (ttyS0/ttyAMA0 depending on arch/config)
    let serialInput = Pipe()
    let serialOutput = Pipe()
    let serialAttachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: serialInput.fileHandleForReading,
      fileHandleForWriting: serialOutput.fileHandleForWriting
    )
    
    // Fallback to Virtio Serial for second port on all architectures since PL011 is problematic with current SDK
    let serialPortConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
    serialPortConfig.attachment = serialAttachment
    
    config.serialPorts.append(serialPortConfig)
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    if attachMemoryBalloon {
      config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
      vmDebug("Memory balloon device attached")
    } else {
      config.memoryBalloonDevices = []
      vmDebug("Memory balloon device disabled")
    }

    if attachLinuxDiskImage {
      let diskURL = try ensureLinuxDiskImage(sizeGB: max(1, VMResourceLimits.linux.diskGB))
      let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
      let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
      config.storageDevices = [blockDevice]
      vmDebug("Disk attachment enabled: \(diskURL.path)")
    } else {
      config.storageDevices = []
      vmDebug("Disk attachment disabled")
    }

    if attachLinuxNetwork {
      let networkDevice = VZVirtioNetworkDeviceConfiguration()
      networkDevice.attachment = VZNATNetworkDeviceAttachment()
      config.networkDevices = [networkDevice]
      vmDebug("Network attachment enabled (NAT)")
    } else {
      config.networkDevices = []
      vmDebug("Network attachment disabled")
    }
    
    consoleInputPipe = consoleInput
    consoleOutputPipe = consoleOutput
    serialInputPipe = serialInput
    serialOutputPipe = serialOutput
    
    try config.validate()
    vmDebug("Minimal configuration validated successfully")
    return config
  }
  
  /// Start a Linux VM for testing
  func startLinuxVM() async throws {
    guard isVirtualizationAvailable else {
      throw VMError.virtualizationNotAvailable
    }
    guard isLinuxReady else {
      throw VMError.linuxNotConfigured
    }
    guard runningLinuxVM == nil else {
      throw VMError.vmAlreadyRunning
    }
    
    statusMessage = "Creating Linux VM configuration..."
    consoleOutput = ""
    
    vmLog("Starting Linux VM")
    vmDebug("Virtualization supported: \(VZVirtualMachine.isSupported)")
    vmDebug("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    vmDebug("Architecture: \(getMachineArchitecture())")
    if isVerboseVMLogging {
      logLinuxVMPreflight()
    }
    
    // Create configuration (minimal diagnostics first)
    let config: VZVirtualMachineConfiguration
    do {
      config = try createMinimalLinuxVMConfiguration()
    } catch {
      print("[VM] ERROR: Failed to create configuration: \(error)")
      statusMessage = "Configuration failed: \(error.localizedDescription)"
      throw error
    }
    
    statusMessage = "Initializing virtual machine..."
    vmDebug("Creating VZVirtualMachine instance...")
    let vm = VZVirtualMachine(configuration: config)
    
    // Set delegate to capture state changes
    let delegate = VMDelegate { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        self.runningLinuxVM = nil
        self.stopConsoleOutputReader()
        if var pool = self.pools["compile:linux"] {
          pool.busyCount = 0
          self.pools["compile:linux"] = pool
        }
        if let error {
          self.statusMessage = "Linux VM stopped: \(error.localizedDescription)"
        } else {
          self.statusMessage = "Linux VM stopped"
        }
      }
    }
    vm.delegate = delegate
    
    vmDebug("VM created, state: \(describeVMState(vm.state))")
    vmDebug("VM can start: \(vm.canStart)")
    
    statusMessage = "Starting Linux VM..."
    vmDebug("Calling vm.start()...")
    
    do {
      let options = VZVirtualMachineStartOptions()
      try await vm.start(options: options)
      vmLog("Linux VM started (state: \(describeVMState(vm.state)))")
      
      runningLinuxVM = vm
      vmDelegate = delegate  // Keep delegate alive

      if isConsoleOutputEnabled {
        startConsoleOutputReader()
      } else {
        vmDebug("Console output reader disabled")
      }
      
      // Update pool counts
      if var pool = pools["compile:linux"] {
        pool.busyCount = 1
        pools["compile:linux"] = pool
      }
      
      statusMessage = "Linux VM running"
      
    } catch let error as NSError {
      vmLog("VM start failed")
      vmDebug("Error domain: \(error.domain)")
      vmDebug("Error code: \(error.code)")
      vmDebug("Description: \(error.localizedDescription)")
      if let reason = error.localizedFailureReason {
        vmDebug("Failure reason: \(reason)")
      }
      if let recovery = error.localizedRecoverySuggestion {
        vmDebug("Recovery suggestion: \(recovery)")
      }
      for (key, value) in error.userInfo {
        vmDebug("UserInfo[\(key)]: \(value)")
      }
      vmDebug("VM start failed diagnostics complete")
      
      statusMessage = "VM start failed"
      var details = error.localizedDescription
      if let reason = error.localizedFailureReason {
        details += " Reason: \(reason)"
      }
      throw VMError.vmCreationFailed(details)
    }
  }
  
  /// Stop the running Linux VM
  func stopLinuxVM() async throws {
    guard let vm = runningLinuxVM else {
      return
    }
    
    statusMessage = "Stopping Linux VM..."
    
    if vm.canRequestStop {
      try vm.requestStop()
      // Give it a moment to shutdown gracefully
      try? await Task.sleep(for: .seconds(2))
    }
    
    if vm.state == .running {
      try await vm.stop()
    }
    
    runningLinuxVM = nil
    stopConsoleOutputReader()
    consoleInputPipe = nil
    consoleOutputPipe = nil
    serialInputPipe = nil
    serialOutputPipe = nil
    
    // Update pool counts
    if var pool = pools["compile:linux"] {
      pool.busyCount = 0
      pools["compile:linux"] = pool
    }
    
    statusMessage = "Linux VM stopped"
  }
  
  /// Create a new Linux VM (returns VM ID)
  func createLinuxVM() async throws -> String {
    guard isVirtualizationAvailable else {
      throw VMError.virtualizationNotAvailable
    }
    guard isLinuxReady else {
      throw VMError.linuxNotConfigured
    }
    
    let vmId = UUID().uuidString
    return vmId
  }
  
  /// Create a new macOS VM (expensive - avoid if possible)
  func createMacOSVM() async throws -> String {
    guard isVirtualizationAvailable else {
      throw VMError.virtualizationNotAvailable
    }
    guard isMacOSReady else {
      throw VMError.macOSRestoreImageNotFound
    }
    
    let vmId = UUID().uuidString
    return vmId
  }

  /// Install macOS into the VM disk (one-time)
  func installMacOSVM() async throws {
    guard isVirtualizationAvailable else {
      throw VMError.virtualizationNotAvailable
    }
    guard isMacOSReady else {
      throw VMError.macOSRestoreImageNotFound
    }
    guard !isMacOSVMInstalled else {
      return
    }
    guard !isMacOSInstalling else {
      return
    }

    guard #available(macOS 12.0, *) else {
      throw VMError.macOSRestoreImageNotFound
    }

    statusMessage = "Preparing macOS installer..."
    let restoreImage = try await loadMacOSRestoreImage()
    let config = try createMacOSVMConfiguration(restoreImage: restoreImage, resources: .macOSBuild)
    let vm = VZVirtualMachine(configuration: config)

    isMacOSInstalling = true
    defer { isMacOSInstalling = false }
    statusMessage = "Installing macOS (this can take a while)..."

    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImage.url)
    macOSInstaller = installer

    try await withCheckedThrowingContinuation { continuation in
      installer.install { result in
        switch result {
        case .success:
          continuation.resume()
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }

    try "installed".write(to: macOSInstallMarkerPath, atomically: true, encoding: .utf8)
    statusMessage = "macOS VM installed"
  }

  /// Start a macOS VM for testing
  func startMacOSVM() async throws {
    guard isVirtualizationAvailable else {
      throw VMError.virtualizationNotAvailable
    }
    guard isMacOSReady else {
      throw VMError.macOSRestoreImageNotFound
    }
    guard runningMacOSVM == nil else {
      throw VMError.vmAlreadyRunning
    }

    if !isMacOSVMInstalled {
      try await installMacOSVM()
    }

    guard #available(macOS 12.0, *) else {
      throw VMError.macOSRestoreImageNotFound
    }

    statusMessage = "Creating macOS VM configuration..."
    let restoreImage = try await loadMacOSRestoreImage()
    let config = try createMacOSVMConfiguration(restoreImage: restoreImage, resources: .macOSBuild)

    let vm = VZVirtualMachine(configuration: config)
    let delegate = VMDelegate { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        self.runningMacOSVM = nil
        if var pool = self.pools["compile:macos"] {
          pool.busyCount = 0
          self.pools["compile:macos"] = pool
        }
        if let error {
          self.statusMessage = "macOS VM stopped: \(error.localizedDescription)"
        } else {
          self.statusMessage = "macOS VM stopped"
        }
      }
    }
    vm.delegate = delegate

    statusMessage = "Starting macOS VM..."
    let options = VZVirtualMachineStartOptions()
    try await vm.start(options: options)

    runningMacOSVM = vm
    macOSVMDelegate = delegate

    if var pool = pools["compile:macos"] {
      pool.busyCount = 1
      pools["compile:macos"] = pool
    }

    statusMessage = "macOS VM running"
  }

  /// Stop the running macOS VM
  func stopMacOSVM() async throws {
    guard let vm = runningMacOSVM else {
      return
    }

    statusMessage = "Stopping macOS VM..."

    if vm.canRequestStop {
      try vm.requestStop()
      try? await Task.sleep(for: .seconds(2))
    }

    if vm.state == .running {
      try await vm.stop()
    }

    runningMacOSVM = nil
    if var pool = pools["compile:macos"] {
      pool.busyCount = 0
      pools["compile:macos"] = pool
    }
    statusMessage = "macOS VM stopped"
  }
  
  /// Download macOS restore image from Apple
  func downloadMacOSRestoreImage() async throws {
#if arch(arm64)
    await MainActor.run {
      statusMessage = "Fetching latest macOS restore image info..."
    }
    
    // VZMacOSRestoreImage.fetchLatestSupported returns info about the latest
    // compatible restore image for this hardware
    guard #available(macOS 12.0, *) else {
      throw VMError.macOSRestoreImageNotFound
    }
    let restoreImage = try await fetchLatestRestoreImageInfo()
    let url = restoreImage.url
    let majorVersion = restoreImage.majorVersion
    let minorVersion = restoreImage.minorVersion
    
    await MainActor.run {
      statusMessage = "Downloading macOS \(majorVersion).\(minorVersion)..."
    }
    
    let macosDir = await MainActor.run { vmBasePath }.appendingPathComponent("macos", isDirectory: true)
    try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
    
    let destinationPath = macosDir.appendingPathComponent("RestoreImage.ipsw")
    
    // Download the image
    // Note: This is a large download (~13GB)
    let (downloadURL, _) = try await URLSession.shared.download(from: url)
    try FileManager.default.moveItem(at: downloadURL, to: destinationPath)
    
    await MainActor.run {
      self.macOSRestoreImagePath = destinationPath
      self.isMacOSReady = true
      self.statusMessage = "macOS restore image ready"
    }
#else
    throw VMError.virtualizationNotAvailable
#endif
  }

#if arch(arm64)
  private struct RestoreImageInfo: Sendable {
    let url: URL
    let majorVersion: Int
    let minorVersion: Int
  }

  @available(macOS 12.0, *)
  private func fetchLatestRestoreImageInfo() async throws -> RestoreImageInfo {
    try await withCheckedThrowingContinuation { continuation in
      VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .success(let image):
          let info = RestoreImageInfo(
            url: image.url,
            majorVersion: image.operatingSystemVersion.majorVersion,
            minorVersion: image.operatingSystemVersion.minorVersion
          )
          continuation.resume(returning: info)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }
#endif
  
  /// Execute a task in the appropriate isolated environment
  func execute(_ task: VMTask) async throws -> VMTaskResult {
    guard isInitialized else {
      throw VMError.notInitialized
    }
    
    // Track active task
    activeTasks[task.id] = task
    defer { activeTasks.removeValue(forKey: task.id) }
    
    let startTime = Date()
    var bootTime: TimeInterval = 0
    
    switch task.environment {
    case .host:
      // Execute directly on host (no isolation)
      return try await executeOnHost(task, startTime: startTime)
      
    case .linux:
      guard isLinuxReady else {
        throw VMError.linuxNotConfigured
      }
      bootTime = 3.0  // Typical Linux VM boot
      // TODO: Actually execute in Linux VM
      
    case .macos:
      guard isMacOSReady else {
        throw VMError.macOSRestoreImageNotFound
      }
      bootTime = 30.0  // Typical macOS VM boot
      // TODO: Actually execute in macOS VM
    }
    
    // Placeholder result for VM execution
    let result = VMTaskResult(
      taskId: task.id,
      environment: task.environment,
      exitCode: 0,
      stdout: "[VM execution not yet implemented for \(task.environment.displayName)]",
      stderr: "",
      executionTime: Date().timeIntervalSince(startTime),
      bootTime: bootTime,
      resourceUsage: VMResourceUsage(
        cpuTimeSeconds: 0,
        peakMemoryMB: 0,
        diskWritesMB: 0,
        networkBytesSent: 0,
        networkBytesReceived: 0
      )
    )
    
    // Store in history
    taskHistory.append(result)
    if taskHistory.count > maxHistoryCount {
      taskHistory.removeFirst(taskHistory.count - maxHistoryCount)
    }
    
    return result
  }
  
  private func executeOnHost(_ task: VMTask, startTime: Date) async throws -> VMTaskResult {
    // Run directly on host using Process
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", task.command]
    
    if let workDir = task.workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workDir)
    }
    
    var env = ProcessInfo.processInfo.environment
    for (key, value) in task.environmentVariables {
      env[key] = value
    }
    process.environment = env
    
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    try process.run()
    process.waitUntilExit()
    
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    
    return VMTaskResult(
      taskId: task.id,
      environment: .host,
      exitCode: process.terminationStatus,
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
      executionTime: Date().timeIntervalSince(startTime),
      bootTime: 0,
      resourceUsage: VMResourceUsage(
        cpuTimeSeconds: 0,
        peakMemoryMB: 0,
        diskWritesMB: 0,
        networkBytesSent: 0,
        networkBytesReceived: 0
      )
    )
  }
  
  // MARK: - Snapshot Management
  
  func createSnapshot(vmId: String, name: String) async throws {
    guard isVirtualizationAvailable else {
      throw VMError.virtualizationNotAvailable
    }
    snapshots[name] = Date()
  }
  
  func restoreSnapshot(vmId: String, snapshotName: String) async throws {
    guard isVirtualizationAvailable else {
      throw VMError.virtualizationNotAvailable
    }
    guard snapshots[snapshotName] != nil else {
      throw VMError.snapshotNotFound(snapshotName)
    }
  }
  
  private func loadSnapshots() async {
    // TODO: Scan vmBasePath for existing snapshots
  }
  
  // MARK: - Support Checks
  
  private func checkVirtualizationSupport() -> Bool {
    if #available(macOS 11.0, *) {
      return VZVirtualMachine.isSupported
    }
    return false
  }

  private func vmLog(_ message: String) {
    print("[VM] \(message)")
  }

  private func vmDebug(_ message: String) {
    guard isVerboseVMLogging else { return }
    print("[VM] \(message)")
  }

  // MARK: - Dependency Management

  func missingToolDependencies() -> [VMToolDependency] {
    requiredDependencies().filter { toolPath(named: $0.tool) == nil }
  }

  func installDependencies(_ deps: [VMToolDependency]) async throws {
    guard !deps.isEmpty else { return }
    guard let brewPath = toolPath(named: "brew") else {
      let hint = isSandboxed()
        ? "Homebrew not found or blocked by the sandbox. Ensure /opt/homebrew/bin/brew exists and is accessible, or run an unsandboxed build."
        : "Homebrew not found. Install Homebrew first: https://brew.sh"
      throw VMError.vmCreationFailed(hint)
    }

    let packages = deps.map { $0.brewPackage }
    statusMessage = "Installing dependencies: \(packages.joined(separator: ", "))"
    print("[Dependencies] Installing: \(packages.joined(separator: ", "))")

    let success = try await runProcess(brewPath, arguments: ["install"] + packages, outputPath: "/tmp/kitchensync_brew_install.log")
    if !success {
      throw VMError.vmCreationFailed("Failed to install dependencies via Homebrew. See /tmp/kitchensync_brew_install.log")
    }
  }

  // MARK: - Initramfs Helpers

  private func ensureLinuxDiskImage(sizeGB: Int) throws -> URL {
    let diskURL = linuxVMDirectory.appendingPathComponent("disk.img")
    if !FileManager.default.fileExists(atPath: diskURL.path) {
      FileManager.default.createFile(atPath: diskURL.path, contents: nil)
      let handle = try FileHandle(forWritingTo: diskURL)
      let diskSize = UInt64(max(1, sizeGB)) * 1024 * 1024 * 1024
      try handle.truncate(atOffset: diskSize)
      try handle.close()
      print("[VM] Created Linux disk image: \(diskURL.path) (\(sizeGB) GB)")
    }
    return diskURL
  }

  private func logLinuxVMPreflight() {
    guard isVerboseVMLogging else { return }
    let linuxDir = linuxVMDirectory
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let initramfsPath = linuxDir.appendingPathComponent("initramfs")
    let diskPath = linuxDir.appendingPathComponent("disk.img")

    print("[VM] Preflight: sandboxed=\(isSandboxed())")
    print("[VM] Preflight: minCPU=\(VZVirtualMachineConfiguration.minimumAllowedCPUCount) maxCPU=\(VZVirtualMachineConfiguration.maximumAllowedCPUCount)")
    print("[VM] Preflight: minMem=\(VZVirtualMachineConfiguration.minimumAllowedMemorySize) maxMem=\(VZVirtualMachineConfiguration.maximumAllowedMemorySize)")

    logFileDiagnostics(label: "Kernel", url: kernelPath)
    logFileDiagnostics(label: "Initramfs", url: initramfsPath)
    logFileDiagnostics(label: "Disk", url: diskPath)

    print("[VM] Preflight: Initramfs format gzip=\(isGzipFile(at: initramfsPath.path)) xz=\(isXZFile(at: initramfsPath.path)) cpio=\(isCpioFile(at: initramfsPath.path))")

    logFileHeader(label: "Kernel", url: kernelPath, length: 64)
    logFileHeader(label: "Initramfs", url: initramfsPath, length: 64)
    logFileHeader(label: "Disk", url: diskPath, length: 64)
    logFileTail(label: "Disk", url: diskPath, length: 64)

    logKernelFormatWarning(kernelPath: kernelPath)
  }

  private func logFileDiagnostics(label: String, url: URL) {
    let path = url.path
    let exists = FileManager.default.fileExists(atPath: path)
    let readable = FileManager.default.isReadableFile(atPath: path)
    let writable = FileManager.default.isWritableFile(atPath: path)
    var sizeBytes: Int64 = 0
    var fileType: FileAttributeType?
    var permissions: NSNumber?
    var owner: String?
    var group: String?
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
      if let size = attrs[.size] as? Int64 {
        sizeBytes = size
      }
      fileType = attrs[.type] as? FileAttributeType
      permissions = attrs[.posixPermissions] as? NSNumber
      owner = attrs[.ownerAccountName] as? String
      group = attrs[.groupOwnerAccountName] as? String
    }
    print("[VM] Preflight: \(label) exists=\(exists) readable=\(readable) writable=\(writable) size=\(sizeBytes) type=\(fileType?.rawValue ?? "unknown") perms=\(permissions?.stringValue ?? "unknown") owner=\(owner ?? "unknown") group=\(group ?? "unknown") path=\(path)")
  }

  private func logFileHeader(label: String, url: URL, length: Int) {
    guard let data = readFileBytes(url: url, offset: 0, length: length) else {
      print("[VM] Preflight: \(label) header=<unreadable>")
      return
    }
    print("[VM] Preflight: \(label) header=\(hexString(from: data))")
  }

  private func logFileTail(label: String, url: URL, length: Int) {
    guard let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else {
      print("[VM] Preflight: \(label) tail=<unreadable>")
      return
    }
    let tailLength = max(0, length)
    let startOffset = max(Int64(0), fileSize - Int64(tailLength))
    guard let data = readFileBytes(url: url, offset: startOffset, length: tailLength) else {
      print("[VM] Preflight: \(label) tail=<unreadable>")
      return
    }
    print("[VM] Preflight: \(label) tail=\(hexString(from: data))")
  }

  private func readFileBytes(url: URL, offset: Int64, length: Int) -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      try handle.seek(toOffset: UInt64(max(0, offset)))
      let data = handle.readData(ofLength: max(0, length))
      try handle.close()
      return data
    } catch {
      print("[VM] Preflight: Read error for \(url.path): \(error)")
      return nil
    }
  }

  private func hexString(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private func logKernelFormatWarning(kernelPath: URL) {
    guard let header = readFileBytes(url: kernelPath, offset: 0, length: 2), header.count == 2 else { return }
    if header[0] == 0x4d && header[1] == 0x5a {
      print("[VM] Preflight: Kernel starts with 'MZ' (PE/COFF EFI). VZLinuxBootLoader may require a raw Linux Image.")
    }
  }

  private func isSandboxed() -> Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }

  private func isGzipFile(at path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    let header = handle.readData(ofLength: 2)
    try? handle.close()
    return header.count == 2 && header[0] == 0x1f && header[1] == 0x8b
  }

  private func isPEKernel(at path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    let header = handle.readData(ofLength: 2)
    try? handle.close()
    return header.count == 2 && header[0] == 0x4d && header[1] == 0x5a
  }

  private func isXZFile(at path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    let header = handle.readData(ofLength: 4)
    try? handle.close()
    return header.count == 4 && header == Data([0xfd, 0x37, 0x7a, 0x58])
  }

  private func toolPath(named tool: String) -> String? {
    let candidates = [
      "/usr/bin/\(tool)",
      "/opt/homebrew/bin/\(tool)",
      "/usr/local/bin/\(tool)"
    ]

    if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return match
    }

    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
      let pathCandidates = pathEnv.split(separator: ":").map { String($0) }
      for dir in pathCandidates {
        let path = (dir as NSString).appendingPathComponent(tool)
        if FileManager.default.isExecutableFile(atPath: path) {
          return path
        }
      }
    }

    if tool == "brew" {
      let fallback = "/opt/homebrew/bin/brew"
      if FileManager.default.fileExists(atPath: fallback) || isSandboxed() {
        return fallback
      }
    }

    return nil
  }

  private func runProcess(_ executable: String, arguments: [String], outputPath: String) async throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    FileManager.default.createFile(atPath: outputPath, contents: nil)
    let outHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()

    let bufferSize = 64 * 1024
    while true {
      let data = outputPipe.fileHandleForReading.readData(ofLength: bufferSize)
      if data.isEmpty { break }
      outHandle.write(data)
    }
    try outHandle.close()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      if let errorText = String(data: errorData, encoding: .utf8), !errorText.isEmpty {
        print("[VM Setup] Process error: \(errorText)")
      }
    }

    return process.terminationStatus == 0
  }

  private func downloadFirstAvailable(urls: [URL], minimumBytes: Int, label: String) async throws -> Data {
    var lastStatus: Int?
    for url in urls {
      print("[VM Setup] Downloading \(label) from \(url.absoluteString)")
      do {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        lastStatus = status
        if status == 200, data.count >= minimumBytes {
          print("[VM Setup] \(label) downloaded: \(data.count) bytes")
          return data
        }
        print("[VM Setup] \(label) download failed (status: \(status), bytes: \(data.count))")
      } catch {
        print("[VM Setup] \(label) download error: \(error)")
      }
    }

    throw VMError.vmCreationFailed("Failed to download \(label) - last HTTP status: \(lastStatus ?? -1)")
  }

  private func isCpioFile(at path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    let header = handle.readData(ofLength: 6)
    try? handle.close()
    // CPIO new ASCII formats start with "070701" or "070702"
    return header == Data([0x30, 0x37, 0x30, 0x37, 0x30, 0x31])
      || header == Data([0x30, 0x37, 0x30, 0x37, 0x30, 0x32])
  }

  

  private func decompressXZ(inputPath: String, outputPath: String) async throws -> Bool {
    guard let xzPath = toolPath(named: "xz") else {
      throw VMError.vmCreationFailed("xz tool not found. Install with 'brew install xz'.")
    }
    print("[VM Setup] Using xz at \(xzPath)")
    return try await runProcess(xzPath, arguments: ["-d", "-c", inputPath], outputPath: outputPath)
  }

  private func decompressGzip(inputPath: String, outputPath: String) async throws -> Bool {
    guard let gzipPath = toolPath(named: "gzip") else {
      throw VMError.vmCreationFailed("gzip tool not found.")
    }
    print("[VM Setup] Using gzip at \(gzipPath)")
    return try await runProcess(gzipPath, arguments: ["-d", "-c", inputPath], outputPath: outputPath)
  }

  private func compressGzip(inputPath: String, outputPath: String) async throws -> Bool {
    guard let gzipPath = toolPath(named: "gzip") else {
      throw VMError.vmCreationFailed("gzip tool not found.")
    }
    print("[VM Setup] Using gzip at \(gzipPath)")
    return try await runProcess(gzipPath, arguments: ["-c", inputPath], outputPath: outputPath)
  }
  
  /// Get the machine architecture string
  private func getMachineArchitecture() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafePointer(to: &sysinfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(cString: $0)
      }
    }
    return machine
  }
  
  /// Describe VM state as a readable string
  private func describeVMState(_ state: VZVirtualMachine.State) -> String {
    switch state {
    case .stopped: return "stopped"
    case .running: return "running"
    case .paused: return "paused"
    case .error: return "error"
    case .starting: return "starting"
    case .pausing: return "pausing"
    case .resuming: return "resuming"
    case .stopping: return "stopping"
    case .saving: return "saving"
    case .restoring: return "restoring"
    @unknown default: return "unknown(\\(state.rawValue))"
    }
  }

  // MARK: - Console Output

  private func startConsoleOutputReader() {
    guard let outputPipe = consoleOutputPipe else { return }

    stopConsoleOutputReader()

    let handle = outputPipe.fileHandleForReading
    let fd = handle.fileDescriptor
    let state = consoleState
    state.clear()

    vmLog("Console output FD: \(fd)")

    VMConsoleReader.start(state: state, fd: fd)

    if let serialPipe = serialOutputPipe {
      let serialFd = serialPipe.fileHandleForReading.fileDescriptor
      vmLog("Serial fallback FD: \(serialFd)")
      VMConsoleReader.start(state: state, fd: serialPipe.fileHandleForReading.fileDescriptor)
      vmLog("Console reader attached to serial fallback")
    }
    vmLog("Console reader started (fd: \(fd))")

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self else { return }
      let bytes = self.consoleState.totalBytesRead()
      if bytes == 0 {
        self.vmLog("Console: no output received after 2s")
      } else {
        self.vmDebug("Console bytes read: \(bytes)")
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
      self?.logConsoleInactivity(thresholdSeconds: 10)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
      self?.logConsoleInactivity(thresholdSeconds: 30)
    }

    consoleFlushTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + consoleFlushInterval, repeating: consoleFlushInterval)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if let chunk = self.consoleState.drain() {
        self.consoleOutput += chunk
        if self.consoleOutput.count > self.consoleMaxOutputChars {
          let tail = self.consoleOutput.suffix(self.consoleMaxOutputChars)
          self.consoleOutput = String(tail)
        }
      } else {
        self.logConsoleInactivity(thresholdSeconds: 10)
      }
    }
    consoleFlushTimer = timer
    timer.resume()
  }

  private func stopConsoleOutputReader() {
    VMConsoleReader.stop(state: consoleState)
    vmLog("Console reader stopped")
    lastConsoleInactivityLogAt = nil
    consoleFlushTimer?.cancel()
    consoleFlushTimer = nil
    consoleReadTask?.cancel()
    consoleReadTask = nil
  }

  private func logConsoleInactivity(thresholdSeconds: TimeInterval) {
    guard let lastOutput = consoleState.lastOutputTimestamp() else { return }
    let sinceLastOutput = Date().timeIntervalSince(lastOutput)
    guard sinceLastOutput >= thresholdSeconds else { return }
    if let lastLog = lastConsoleInactivityLogAt, Date().timeIntervalSince(lastLog) < thresholdSeconds {
      return
    }
    lastConsoleInactivityLogAt = Date()
    vmLog("Console: no output for \(Int(sinceLastOutput))s (threshold \(Int(thresholdSeconds))s)")
  }

  nonisolated private func flushConsoleBufferIfNeeded(force: Bool) {
    _ = force
  }

  func setConsoleOutputEnabled(_ enabled: Bool) {
    isConsoleOutputEnabled = enabled
    vmLog("Console output \(enabled ? "enabled" : "disabled")")
    if enabled {
      if runningLinuxVM != nil {
        startConsoleOutputReader()
      }
    } else {
      stopConsoleOutputReader()
    }
  }

  func clearConsoleOutput() {
    consoleOutput = ""
  }

  func sendConsoleInput(_ input: String) {
    let payload = input.hasSuffix("\n") ? input : input + "\n"
    guard let data = payload.data(using: .utf8) else { return }
    let pipes = [consoleInputPipe, serialInputPipe].compactMap { $0 }
    for pipe in pipes {
      do {
        try pipe.fileHandleForWriting.write(contentsOf: data)
      } catch {
        print("[VM] Failed to write to console input: \(error)")
      }
    }
  }
  
  // MARK: - Pool Management
  
  func getPoolStatus() -> [String: VMPool] {
    pools
  }
  
  func setPoolMax(_ tier: VMCapabilityTier, environment: ExecutionEnvironment, maxCount: Int) {
    let key = "\(tier.rawValue):\(environment.rawValue)"
    if var pool = pools[key] {
      pool.maxCount = maxCount
      pools[key] = pool
    }
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
  case snapshotNotFound(String)
  case vmCreationFailed(String)
  case vmAlreadyRunning
  
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
    case .snapshotNotFound(let name):
      "Snapshot '\(name)' not found"
    case .vmCreationFailed(let reason):
      "Failed to create VM: \(reason)"
    case .vmAlreadyRunning:
      "A Linux VM is already running"
    }
  }
}

#endif // os(macOS)
