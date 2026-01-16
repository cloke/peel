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
  
  // MARK: - Configuration
  
  /// Base path for VM disk images and configs
  private let vmBasePath: URL
  
  /// Maximum tasks to keep in history
  private let maxHistoryCount = 100
  
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
    // Check if we have a Linux kernel and rootfs
    let linuxDir = linuxVMDirectory
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let rootfsPath = linuxDir.appendingPathComponent("rootfs.img")
    
    isLinuxReady = FileManager.default.fileExists(atPath: kernelPath.path) &&
                   FileManager.default.fileExists(atPath: rootfsPath.path)
  }
  
  /// Download and set up Alpine Linux for lightweight VMs
  /// This downloads a minimal Alpine Linux (~50MB) suitable for agent tasks
  func setupLinuxVM() async throws {
    statusMessage = "Setting up Linux VM environment..."
    
    let linuxDir = linuxVMDirectory
    try FileManager.default.createDirectory(at: linuxDir, withIntermediateDirectories: true)
    
    // Alpine Linux Virtual - minimal cloud/VM image
    // Using the "virtual" flavor which is optimized for VMs
    let alpineVersion = "3.19"
    let alpineArch = "aarch64"  // Apple Silicon
    
    // Download kernel
    statusMessage = "Downloading Alpine Linux kernel..."
    let kernelURL = URL(string: "https://dl-cdn.alpinelinux.org/alpine/v\(alpineVersion)/releases/\(alpineArch)/netboot/vmlinuz-virt")!
    let (kernelData, _) = try await URLSession.shared.data(from: kernelURL)
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    try kernelData.write(to: kernelPath)
    
    // Download initramfs
    statusMessage = "Downloading Alpine Linux initramfs..."
    let initrdURL = URL(string: "https://dl-cdn.alpinelinux.org/alpine/v\(alpineVersion)/releases/\(alpineArch)/netboot/initramfs-virt")!
    let (initrdData, _) = try await URLSession.shared.data(from: initrdURL)
    let initrdPath = linuxDir.appendingPathComponent("initramfs")
    try initrdData.write(to: initrdPath)
    
    // Create a minimal root filesystem disk image
    statusMessage = "Creating root filesystem..."
    let rootfsPath = linuxDir.appendingPathComponent("rootfs.img")
    
    // Create a 2GB sparse disk image
    let diskSize: UInt64 = 2 * 1024 * 1024 * 1024  // 2GB
    FileManager.default.createFile(atPath: rootfsPath.path, contents: nil)
    let handle = try FileHandle(forWritingTo: rootfsPath)
    try handle.truncate(atOffset: diskSize)
    try handle.close()
    
    isLinuxReady = true
    statusMessage = "Linux VM ready"
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
  private func createLinuxVMConfiguration() throws -> VZVirtualMachineConfiguration {
    let linuxDir = linuxVMDirectory
    let kernelPath = linuxDir.appendingPathComponent("vmlinuz")
    let initramfsPath = linuxDir.appendingPathComponent("initramfs")
    let rootfsPath = linuxDir.appendingPathComponent("rootfs.img")
    
    // Boot loader
    let bootLoader = VZLinuxBootLoader(kernelURL: kernelPath)
    bootLoader.initialRamdiskURL = initramfsPath
    bootLoader.commandLine = "console=hvc0"
    
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    
    // CPU and memory
    config.cpuCount = 2
    config.memorySize = 2 * 1024 * 1024 * 1024  // 2GB
    
    // Platform (generic for Linux)
    let platform = VZGenericPlatformConfiguration()
    config.platform = platform
    
    // Console (virtio)
    let consoleDevice = VZVirtioConsoleDeviceConfiguration()
    let serialPort = VZVirtioConsolePortConfiguration()
    serialPort.name = "console"
    consoleDevice.ports[0] = serialPort
    config.consoleDevices = [consoleDevice]
    
    // Storage (root filesystem)
    if FileManager.default.fileExists(atPath: rootfsPath.path) {
      let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: rootfsPath, readOnly: false)
      let storageDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
      config.storageDevices = [storageDevice]
    }
    
    // Network (NAT)
    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [networkDevice]
    
    // Entropy (required for Linux)
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    
    // Memory balloon (for dynamic memory)
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    
    try config.validate()
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
    
    statusMessage = "Creating Linux VM..."
    consoleOutput = ""
    
    let config = try createLinuxVMConfiguration()
    let vm = VZVirtualMachine(configuration: config)
    
    statusMessage = "Starting Linux VM..."
    
    try await vm.start()
    runningLinuxVM = vm
    
    // Update pool counts
    if var pool = pools["compile:linux"] {
      pool.busyCount = 1
      pools["compile:linux"] = pool
    }
    
    statusMessage = "Linux VM running"
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
