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
import Virtualization

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
    memoryGB: 2,
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

// MARK: - Linux VM Configuration

/// Configuration for lightweight Linux VMs
struct LinuxVMConfig: Sendable {
  /// Path to Linux kernel (vmlinuz)
  let kernelPath: URL
  
  /// Path to initial ramdisk (initrd)
  let initrdPath: URL?
  
  /// Path to root filesystem disk image
  let rootFSPath: URL
  
  /// Kernel command line arguments
  let commandLine: String
  
  /// Resources allocated to this VM
  let resources: VMResourceLimits
  
  /// Default config for a minimal Alpine Linux VM
  static func alpine(rootFSPath: URL, kernelPath: URL) -> LinuxVMConfig {
    LinuxVMConfig(
      kernelPath: kernelPath,
      initrdPath: nil,
      rootFSPath: rootFSPath,
      commandLine: "console=hvc0 root=/dev/vda rw",
      resources: .linux
    )
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
  
  /// Whether a Linux VM is currently running
  var isLinuxVMRunning: Bool { runningLinuxVM?.state == .running }
  
  /// Console output from the running VM
  private(set) var consoleOutput: String = ""
  
  /// VM delegate (kept alive while VM is running)
  private var vmDelegate: VMDelegate?

  /// Console pipes (kept alive while VM is running)
  private var consoleInputPipe: Pipe?
  private var consoleOutputPipe: Pipe?
  private var consoleReadTask: Task<Void, Never>?
  
  // MARK: - Configuration
  
  /// Base path for VM disk images and configs
  private let vmBasePath: URL
  
  /// Maximum tasks to keep in history
  private let maxHistoryCount = 100

  // MARK: - Dependencies

  private let requiredDependencies: [VMToolDependency] = [
    VMToolDependency(tool: "xz", brewPackage: "xz", purpose: "Decompress Fedora initramfs")
  ]
  
  // MARK: - Initialization
  
  init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
  
  private func checkLinuxVMSupport() async {
    // Check if we have a Linux kernel and initramfs
    let linuxDir = linuxVMDirectory
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let initramfsPath = linuxDir.appendingPathComponent("initramfs")
    
    let kernelExists = FileManager.default.fileExists(atPath: kernelPath.path)
    let initramfsExists = FileManager.default.fileExists(atPath: initramfsPath.path)
    let initramfsIsGzip = initramfsExists && isGzipFile(at: initramfsPath.path)
    let initramfsIsXZ = initramfsExists && isXZFile(at: initramfsPath.path)
    
    isLinuxReady = kernelExists && initramfsExists && initramfsIsGzip
    
    // Log what we found for debugging
    if isLinuxReady {
      if let kernelAttrs = try? FileManager.default.attributesOfItem(atPath: kernelPath.path),
         let initramfsAttrs = try? FileManager.default.attributesOfItem(atPath: initramfsPath.path) {
        let kernelSize = kernelAttrs[.size] as? Int ?? 0
        let initramfsSize = initramfsAttrs[.size] as? Int ?? 0
        print("Linux VM files found - kernel: \(kernelSize) bytes, initramfs: \(initramfsSize) bytes")
      }
    } else if initramfsIsXZ {
      print("Linux VM initramfs is XZ-compressed; needs GZIP. Re-run setup.")
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
  /// Downloads Fedora kernel and initramfs - recommended by Apple's documentation
  func setupLinuxVM() async throws {
    statusMessage = "Setting up Linux VM environment..."
    
    let linuxDir = linuxVMDirectory
    try FileManager.default.createDirectory(at: linuxDir, withIntermediateDirectories: true)
    
    // Use Fedora - Apple's official documentation recommends Fedora for Virtualization.framework
    // https://developer.apple.com/documentation/virtualization/running_linux_in_a_virtual_machine
    // "You may obtain a kernel image and the corresponding initial RAM disk image for a
    //  given release of the Fedora Linux distribution"
    
    let fedoraReleases = ["40", "39"]  // Fallbacks for compatibility
    let arch = "aarch64"      // Apple Silicon
    let fedoraBases = fedoraReleases.flatMap { release in
      [
        "https://download.fedoraproject.org/pub/fedora/linux/releases/\(release)/Everything/\(arch)/os/images/pxeboot",
        "https://fedora.mirror.constant.com/fedora/linux/releases/\(release)/Everything/\(arch)/os/images/pxeboot"
      ]
    }
    
    // Download kernel (vmlinuz)
    statusMessage = "Downloading Fedora kernel (vmlinuz)..."
    let kernelURLs = fedoraBases.compactMap { URL(string: "\($0)/vmlinuz") }
    let kernelResult = try await downloadFirstAvailable(
      urls: kernelURLs,
      minimumBytes: 1_000_000,
      label: "Fedora kernel"
    )
    let kernelData = kernelResult.data
    let selectedRelease = kernelResult.release
    
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    try kernelData.write(to: kernelPath)
    
    // Download initramfs (initrd.img)
    statusMessage = "Downloading Fedora initramfs (~150MB, XZ format)..."
    let initrdURLs = fedoraBases.compactMap { URL(string: "\($0)/initrd.img") }
    let initrdResult = try await downloadFirstAvailable(
      urls: initrdURLs,
      minimumBytes: 10_000_000,
      label: "Fedora initramfs"
    )
    let initrdData = initrdResult.data

    // Write the XZ-compressed initramfs to disk temporarily
    let initrdXZPath = linuxDir.appendingPathComponent("initramfs.xz")
    try initrdData.write(to: initrdXZPath)

    // Decompress XZ to raw initramfs
    statusMessage = "Decompressing initramfs (XZ → raw)..."
    print("[VM Setup] Decompressing initramfs (XZ → raw)")
    let initrdRawPath = linuxDir.appendingPathComponent("initramfs.raw")
    let xzResult = try await decompressXZ(inputPath: initrdXZPath.path, outputPath: initrdRawPath.path)
    guard xzResult else {
      throw VMError.vmCreationFailed("Failed to decompress XZ initramfs. Ensure 'xz' is installed.")
    }

    // Compress to GZIP
    statusMessage = "Compressing initramfs (raw → GZIP)..."
    print("[VM Setup] Compressing initramfs (raw → GZIP)")
    let initrdGZPath = linuxDir.appendingPathComponent("initramfs")
    let gzipResult = try await compressGzip(inputPath: initrdRawPath.path, outputPath: initrdGZPath.path)
    guard gzipResult else {
      throw VMError.vmCreationFailed("Failed to compress initramfs to GZIP. Ensure 'gzip' is available.")
    }
    guard isGzipFile(at: initrdGZPath.path) else {
      throw VMError.vmCreationFailed("Initramfs conversion failed. Output is not GZIP.")
    }
    print("[VM Setup] Initramfs converted to GZIP format.")

    // Clean up temp files
    try? FileManager.default.removeItem(at: initrdXZPath)
    try? FileManager.default.removeItem(at: initrdRawPath)

    // Create marker file
    let markerPath = linuxDir.appendingPathComponent(".distro")
    try "fedora-\(selectedRelease)".write(to: markerPath, atomically: true, encoding: .utf8)

    isLinuxReady = true
    statusMessage = "Fedora \(selectedRelease) Linux VM ready (initramfs converted to GZIP)"
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
  
  // MARK: - VM Lifecycle
  
  /// Create and configure a Linux VM
  /// - Parameter minimal: If true, uses minimal configuration (fewer devices)
  /// - Parameter noInitramfs: If true, skips initramfs (for debugging only - won't boot to shell)
  private func createLinuxVMConfiguration(minimal: Bool = false, noInitramfs: Bool = false) throws -> VZVirtualMachineConfiguration {
    let linuxDir = linuxVMDirectory
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let initramfsPath = linuxDir.appendingPathComponent("initramfs")
    let rootfsPath = linuxDir.appendingPathComponent("rootfs.img")
    
    print("[VM] Creating Linux VM configuration (minimal: \(minimal))...")
    print("[VM] Linux directory: \(linuxDir.path)")
    print("[VM] Kernel path: \(kernelPath.path)")
    print("[VM] Initramfs path: \(initramfsPath.path)")
    print("[VM] Rootfs path: \(rootfsPath.path)")
    
    // Verify required files exist and log their sizes
    guard FileManager.default.fileExists(atPath: kernelPath.path) else {
      print("[VM] ERROR: Kernel not found!")
      throw VMError.vmCreationFailed("Kernel not found at \(kernelPath.path)")
    }
    guard FileManager.default.fileExists(atPath: initramfsPath.path) else {
      print("[VM] ERROR: Initramfs not found!")
      throw VMError.vmCreationFailed("Initramfs not found at \(initramfsPath.path)")
    }
    
    // Log file details
    if let kernelAttrs = try? FileManager.default.attributesOfItem(atPath: kernelPath.path) {
      let size = kernelAttrs[.size] as? Int64 ?? 0
      let perms = kernelAttrs[.posixPermissions] as? Int ?? 0
      print("[VM] Kernel: \(size) bytes, permissions: \(String(perms, radix: 8))")
      
      // Check kernel file header (should be PE/EFI for arm64)
      if let handle = FileHandle(forReadingAtPath: kernelPath.path) {
        let header = handle.readData(ofLength: 4)
        try? handle.close()
        let headerHex = header.map { String(format: "%02x", $0) }.joined()
        print("[VM] Kernel header: \(headerHex)")
        // PE format starts with 'MZ' (4d5a)
        if header.count >= 2 && header[0] == 0x4d && header[1] == 0x5a {
          print("[VM] Kernel format: PE/EFI executable (correct)")
        } else {
          print("[VM] WARNING: Kernel may not be in correct PE/EFI format!")
        }
      }
    }
    if let initramfsAttrs = try? FileManager.default.attributesOfItem(atPath: initramfsPath.path) {
      let size = initramfsAttrs[.size] as? Int64 ?? 0
      let perms = initramfsAttrs[.posixPermissions] as? Int ?? 0
      print("[VM] Initramfs: \(size) bytes, permissions: \(String(perms, radix: 8))")
      
      // Check initramfs header (should be gzip: 1f 8b)
      if let handle = FileHandle(forReadingAtPath: initramfsPath.path) {
        let header = handle.readData(ofLength: 4)
        try? handle.close()
        let headerHex = header.map { String(format: "%02x", $0) }.joined()
        print("[VM] Initramfs header: \(headerHex)")
        if header.count >= 2 && header[0] == 0x1f && header[1] == 0x8b {
          print("[VM] Initramfs format: gzip compressed (correct)")
        } else if header.count >= 4 && header[0...3] == Data([0x30, 0x37, 0x30, 0x37]) {
          print("[VM] Initramfs format: cpio archive (correct)")
        } else {
          print("[VM] WARNING: Initramfs may not be in correct format!")
        }
      }
    }
    
    // Check file readability
    guard FileManager.default.isReadableFile(atPath: kernelPath.path) else {
      print("[VM] ERROR: Kernel file is not readable!")
      throw VMError.vmCreationFailed("Kernel file is not readable")
    }
    guard FileManager.default.isReadableFile(atPath: initramfsPath.path) else {
      print("[VM] ERROR: Initramfs file is not readable!")
      throw VMError.vmCreationFailed("Initramfs file is not readable")
    }
    if isXZFile(at: initramfsPath.path) {
      print("[VM] ERROR: Initramfs is XZ-compressed. Expected GZIP.")
      throw VMError.vmCreationFailed("Initramfs is XZ-compressed. Re-run Setup Linux VM to convert to GZIP.")
    }
    
    print("[VM] Creating boot loader...")
    let bootLoader = VZLinuxBootLoader(kernelURL: kernelPath)
    if noInitramfs {
      print("[VM] Skipping initramfs (debug mode)")
      bootLoader.commandLine = "console=hvc0 panic=1"
    } else {
      bootLoader.initialRamdiskURL = initramfsPath
      // Use Fedora-recommended command line from Apple's sample code
      // "rd.break=initqueue" stops in initramfs before trying to mount root
      // This is perfect for testing - we get a shell without needing a root filesystem
      let commandLine = minimal
        ? "console=hvc0 rd.break=initqueue"
        : "console=hvc0 rd.break=initqueue"
      bootLoader.commandLine = commandLine
    }
    print("[VM] Boot command line: \(bootLoader.commandLine)")
    
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    
    // CPU - try just 1 for minimal
    let physicalCores = ProcessInfo.processInfo.processorCount
    let cpuCount = min(2, max(1, physicalCores))
    config.cpuCount = cpuCount
    print("[VM] CPU count: \(cpuCount) (physical: \(physicalCores))")
    
    // Memory - VZVirtualMachineConfiguration.minimumAllowedMemorySize is 128MB
    // But Linux needs more - use 512MB minimum
    let minimumMemory: UInt64 = 512 * 1024 * 1024  // 512MB
    let desiredMemory: UInt64 = 2 * 1024 * 1024 * 1024  // 2GB (matches Apple sample)
    config.memorySize = max(desiredMemory, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    print("[VM] Memory: \(config.memorySize / 1024 / 1024) MB (minimum: \(VZVirtualMachineConfiguration.minimumAllowedMemorySize / 1024 / 1024) MB)")
    
    // Platform (generic for Linux)
    let platform = VZGenericPlatformConfiguration()
    config.platform = platform
    print("[VM] Platform: Generic (Linux)")
    
    // Virtio console for serial I/O (serial port attachment)
    let serialPortConfig = VZVirtioConsoleDeviceSerialPortConfiguration()

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let attachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: inputPipe.fileHandleForReading,
      fileHandleForWriting: outputPipe.fileHandleForWriting
    )
    serialPortConfig.attachment = attachment
    config.serialPorts = [serialPortConfig]

    consoleInputPipe = inputPipe
    consoleOutputPipe = outputPipe
    print("[VM] Console: Serial port configured")
    
    // In minimal mode, skip optional devices to isolate the issue
    if !minimal {
      // Storage - rootfs disk image (optional - we can boot from initramfs)
      if FileManager.default.fileExists(atPath: rootfsPath.path) {
        do {
          if let diskAttrs = try? FileManager.default.attributesOfItem(atPath: rootfsPath.path) {
            let size = diskAttrs[.size] as? Int64 ?? 0
            print("[VM] Disk image: \(rootfsPath.lastPathComponent) - \(size / 1024 / 1024) MB")
          }
          let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: rootfsPath, readOnly: false)
          let storageDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
          config.storageDevices = [storageDevice]
          print("[VM] Storage: Disk attached successfully")
        } catch {
          // Non-fatal - we can boot without the disk
          print("[VM] Warning: Could not attach disk image: \(error)")
        }
      } else {
        print("[VM] Storage: No disk image found (booting from initramfs only)")
      }
      
      // Network (NAT) - optional but useful
      let networkDevice = VZVirtioNetworkDeviceConfiguration()
      networkDevice.attachment = VZNATNetworkDeviceAttachment()
      config.networkDevices = [networkDevice]
      print("[VM] Network: NAT configured")
      
      // Memory balloon (for dynamic memory management)
      config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
      print("[VM] Memory balloon: Configured")
    } else {
      print("[VM] Minimal mode: Skipping storage, network, memory balloon")
    }
    
    // Entropy (required for Linux to have randomness)
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    print("[VM] Entropy: Configured")
    
    // Validate configuration before returning
    print("[VM] Validating configuration...")
    do {
      try config.validate()
      print("[VM] Configuration validated successfully")
    } catch {
      print("[VM] ERROR: Configuration validation failed: \(error)")
      throw error
    }
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
    
    print("[VM] ========== Starting Linux VM ==========")
    print("[VM] Virtualization supported: \(VZVirtualMachine.isSupported)")
    print("[VM] System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("[VM] Architecture: \(getMachineArchitecture())")
    
    // Create configuration (using standard full config)
    let config: VZVirtualMachineConfiguration
    do {
      config = try createLinuxVMConfiguration(minimal: true, noInitramfs: false)
    } catch {
      print("[VM] ERROR: Failed to create configuration: \(error)")
      statusMessage = "Configuration failed: \(error.localizedDescription)"
      throw error
    }
    
    statusMessage = "Initializing virtual machine..."
    print("[VM] Creating VZVirtualMachine instance...")
    let vm = VZVirtualMachine(configuration: config)
    
    // Set delegate to capture state changes
    let delegate = VMDelegate()
    vm.delegate = delegate
    
    print("[VM] VM created, state: \(describeVMState(vm.state))")
    print("[VM] VM can start: \(vm.canStart)")
    
    statusMessage = "Starting Linux VM..."
    print("[VM] Calling vm.start()...")
    
    do {
      let options = VZVirtualMachineStartOptions()
      try await vm.start(options: options)
      print("[VM] VM started successfully, state: \(describeVMState(vm.state))")
      
      runningLinuxVM = vm
      vmDelegate = delegate  // Keep delegate alive

      startConsoleOutputReader()
      
      // Update pool counts
      if var pool = pools["compile:linux"] {
        pool.busyCount = 1
        pools["compile:linux"] = pool
      }
      
      statusMessage = "Linux VM running"
      
    } catch let error as NSError {
      print("[VM] ========== VM START FAILED ==========")
      print("[VM] Error domain: \(error.domain)")
      print("[VM] Error code: \(error.code)")
      print("[VM] Description: \(error.localizedDescription)")
      if let reason = error.localizedFailureReason {
        print("[VM] Failure reason: \(reason)")
      }
      if let recovery = error.localizedRecoverySuggestion {
        print("[VM] Recovery suggestion: \(recovery)")
      }
      for (key, value) in error.userInfo {
        print("[VM] UserInfo[\(key)]: \(value)")
      }
      print("[VM] ========================================")
      
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
    
    // TODO: Actually create VZVirtualMachine for macOS
    // This requires VZMacOSBootLoader, hardware model, machine identifier
    
    let vmId = UUID().uuidString
    return vmId
  }
  
  /// Download macOS restore image from Apple
  nonisolated func downloadMacOSRestoreImage() async throws {
    await MainActor.run {
      statusMessage = "Fetching latest macOS restore image info..."
    }
    
    // VZMacOSRestoreImage.fetchLatestSupported returns info about the latest
    // compatible restore image for this hardware
    let restoreImage = try await VZMacOSRestoreImage.latestSupported
    let url = restoreImage.url
    let majorVersion = restoreImage.operatingSystemVersion.majorVersion
    let minorVersion = restoreImage.operatingSystemVersion.minorVersion
    
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
  }
  
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

  // MARK: - Dependency Management

  func missingToolDependencies() -> [VMToolDependency] {
    requiredDependencies.filter { toolPath(named: $0.tool) == nil }
  }

  func installDependencies(_ deps: [VMToolDependency]) async throws {
    guard !deps.isEmpty else { return }
    guard let brewPath = toolPath(named: "brew") else {
      throw VMError.vmCreationFailed("Homebrew not found. Install Homebrew first: https://brew.sh")
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

  private func isGzipFile(at path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    let header = handle.readData(ofLength: 2)
    try? handle.close()
    return header.count == 2 && header[0] == 0x1f && header[1] == 0x8b
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
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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

  private func downloadFirstAvailable(urls: [URL], minimumBytes: Int, label: String) async throws -> (data: Data, release: String) {
    var lastStatus: Int?
    for url in urls {
      let release = extractFedoraRelease(from: url)
      print("[VM Setup] Downloading \(label) from \(url.absoluteString)")
      do {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        lastStatus = status
        if status == 200, data.count >= minimumBytes {
          print("[VM Setup] \(label) downloaded: \(data.count) bytes")
          return (data, release)
        }
        print("[VM Setup] \(label) download failed (status: \(status), bytes: \(data.count))")
      } catch {
        print("[VM Setup] \(label) download error: \(error)")
      }
    }

    throw VMError.vmCreationFailed("Failed to download \(label) - last HTTP status: \(lastStatus ?? -1)")
  }

  private func extractFedoraRelease(from url: URL) -> String {
    let path = url.path
    let parts = path.split(separator: "/")
    if let index = parts.firstIndex(of: "releases"), index + 1 < parts.count {
      return String(parts[index + 1])
    }
    return "unknown"
  }

  private func decompressXZ(inputPath: String, outputPath: String) async throws -> Bool {
    guard let xzPath = toolPath(named: "xz") else {
      throw VMError.vmCreationFailed("xz tool not found. Install with 'brew install xz'.")
    }
    print("[VM Setup] Using xz at \(xzPath)")
    return try await runProcess(xzPath, arguments: ["-d", "-c", inputPath], outputPath: outputPath)
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
    consoleReadTask?.cancel()
    consoleReadTask = Task { [weak self] in
      let handle = outputPipe.fileHandleForReading
      while !Task.isCancelled {
        let data = handle.readData(ofLength: 4096)
        if data.isEmpty { break }
        if let text = String(data: data, encoding: .utf8) {
          await MainActor.run {
            self?.consoleOutput += text
          }
        }
      }
    }
  }

  private func stopConsoleOutputReader() {
    consoleReadTask?.cancel()
    consoleReadTask = nil
    consoleInputPipe = nil
    consoleOutputPipe = nil
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
  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: (any Error)?) {
    if let error = error {
      print("[VM Delegate] VM stopped with error: \(error)")
      if let nsError = error as NSError? {
        print("[VM Delegate] Error domain: \(nsError.domain), code: \(nsError.code)")
        for (key, value) in nsError.userInfo {
          print("[VM Delegate] UserInfo[\(key)]: \(value)")
        }
      }
    } else {
      print("[VM Delegate] VM stopped normally")
    }
  }
  
  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    print("[VM Delegate] Guest did stop")
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
