// DistributedTypes.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// Shared types for distributed task execution between Peel instances.

import Foundation

// MARK: - Chain Request

/// A request to execute a chain on a remote worker
public struct ChainRequest: Codable, Sendable, Identifiable {
  /// Unique request identifier
  public let id: UUID
  public let templateName: String
  public let prompt: String
  public let workingDirectory: String
  /// The git remote URL (e.g., git@github.com:user/repo.git) - stable identifier across machines
  public let repoRemoteURL: String?
  public let priority: ChainPriority
  public let requiredCapabilities: RequiredCapabilities?
  public let createdAt: Date
  public let timeoutSeconds: Int
  
  public init(
    id: UUID = UUID(),
    templateName: String,
    prompt: String,
    workingDirectory: String,
    repoRemoteURL: String? = nil,
    priority: ChainPriority = .normal,
    requiredCapabilities: RequiredCapabilities? = nil,
    createdAt: Date = Date(),
    timeoutSeconds: Int = 300
  ) {
    self.id = id
    self.templateName = templateName
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    self.repoRemoteURL = repoRemoteURL
    self.priority = priority
    self.requiredCapabilities = requiredCapabilities
    self.createdAt = createdAt
    self.timeoutSeconds = timeoutSeconds
  }
}

// MARK: - Chain Priority

/// Priority level for chain execution (renamed from TaskPriority to avoid collision)
public enum ChainPriority: Int, Codable, Sendable, Comparable {
  case low = 0
  case normal = 1
  case high = 2
  case critical = 3
  
  public static func < (lhs: ChainPriority, rhs: ChainPriority) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

// MARK: - Required Capabilities

/// Minimum capabilities a worker must have to execute a task
public struct RequiredCapabilities: Codable, Sendable {
  public let minGPUCores: Int?
  public let minMemoryGB: Int?
  public let requiredRepos: [String]?
  public let requiresNeuralEngine: Bool
  
  public init(
    minGPUCores: Int? = nil,
    minMemoryGB: Int? = nil,
    requiredRepos: [String]? = nil,
    requiresNeuralEngine: Bool = false
  ) {
    self.minGPUCores = minGPUCores
    self.minMemoryGB = minMemoryGB
    self.requiredRepos = requiredRepos
    self.requiresNeuralEngine = requiresNeuralEngine
  }
  
  /// Check if a worker's capabilities meet these requirements
  public func isSatisfiedBy(_ capabilities: WorkerCapabilities) -> Bool {
    if let minGPU = minGPUCores, capabilities.gpuCores < minGPU {
      return false
    }
    if let minMem = minMemoryGB, capabilities.memoryGB < minMem {
      return false
    }
    if let repos = requiredRepos {
      let indexed = Set(capabilities.indexedRepos)
      if !repos.allSatisfy({ indexed.contains($0) }) {
        return false
      }
    }
    if requiresNeuralEngine && capabilities.neuralEngineCores == 0 {
      return false
    }
    return true
  }
}

// MARK: - Chain Result

/// The result of executing a chain on a worker
public struct ChainResult: Codable, Sendable {
  public let requestId: UUID
  public let status: ChainStatus
  public let outputs: [ChainOutput]
  public let duration: TimeInterval
  public let workerDeviceId: String
  public let workerDeviceName: String
  public let completedAt: Date
  public let errorMessage: String?
  /// Branch name created for this task (if worktree isolation was used)
  public let branchName: String?
  /// Path to the repo where the branch was created
  public let repoPath: String?
  
  public init(
    requestId: UUID,
    status: ChainStatus,
    outputs: [ChainOutput] = [],
    duration: TimeInterval,
    workerDeviceId: String,
    workerDeviceName: String,
    completedAt: Date = Date(),
    errorMessage: String? = nil,
    branchName: String? = nil,
    repoPath: String? = nil
  ) {
    self.requestId = requestId
    self.status = status
    self.outputs = outputs
    self.duration = duration
    self.workerDeviceId = workerDeviceId
    self.workerDeviceName = workerDeviceName
    self.completedAt = completedAt
    self.errorMessage = errorMessage
    self.branchName = branchName
    self.repoPath = repoPath
  }
}

// MARK: - Chain Status

public enum ChainStatus: String, Codable, Sendable {
  case pending
  case claimed
  case running
  case completed
  case failed
  case cancelled
  case timedOut
}

// MARK: - Chain Output

/// A single output artifact from chain execution.
/// Use `content` for inline payloads and `filePath` for large outputs.
public struct ChainOutput: Codable, Sendable {
  public let type: OutputType
  public let name: String
  public let content: String?
  public let filePath: String?
  public let mimeType: String?
  
  public enum OutputType: String, Codable, Sendable {
    case text
    case file
    case diff
    case log
  }
  
  public init(type: OutputType, name: String, content: String? = nil, filePath: String? = nil, mimeType: String? = nil) {
    self.type = type
    self.name = name
    self.content = content
    self.filePath = filePath
    self.mimeType = mimeType
  }
}

// MARK: - Network Utilities

/// Utilities for network address detection
public enum NetworkUtils {
  /// Fetch public IP address from external services
  /// Returns nil if detection fails
  public static func fetchPublicIP() async -> String? {
    // Try multiple services for reliability
    let services = [
      "https://api.ipify.org",
      "https://ifconfig.me/ip",
      "https://icanhazip.com"
    ]
    
    for service in services {
      guard let url = URL(string: service) else { continue }
      do {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidIPv4(ip) else {
          continue
        }
        return ip
      } catch {
        continue
      }
    }
    return nil
  }
  
  /// Check if string is a valid IPv4 address
  private static func isValidIPv4(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".")
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      guard let num = Int(part) else { return false }
      return num >= 0 && num <= 255
    }
  }
}

// MARK: - Peel Capabilities

/// Hardware and software capabilities of a worker node
public struct WorkerCapabilities: Codable, Sendable, Identifiable {
  public var id: String { deviceId }
  
  public let deviceId: String
  public let deviceName: String      // Raw hostname
  public let displayName: String?    // Custom friendly name (from config)
  public let platform: Platform
  
  // Hardware
  public let gpuCores: Int
  public let neuralEngineCores: Int
  public let memoryGB: Int
  public let storageAvailableGB: Int
  
  // Software
  public let embeddingModel: String?
  public let embeddingDimensions: Int?
  public let indexedRepos: [String]
  public let gitCommitHash: String?  // Short git commit hash for version sync
  
  // Network - LAN (local network discovery)
  public let lanAddress: String?
  public let lanPort: UInt16?
  
  // Network - WAN (internet-routable address for cross-network peers)
  public let wanAddress: String?
  public let wanPort: UInt16?
  
  public enum Platform: String, Codable, Sendable {
    case macOS
    case iOS
    case visionOS
  }
  
  public init(
    deviceId: String,
    deviceName: String,
    displayName: String? = nil,
    platform: Platform,
    gpuCores: Int,
    neuralEngineCores: Int,
    memoryGB: Int,
    storageAvailableGB: Int,
    embeddingModel: String? = nil,
    embeddingDimensions: Int? = nil,
    indexedRepos: [String] = [],
    gitCommitHash: String? = nil,
    lanAddress: String? = nil,
    lanPort: UInt16? = nil,
    wanAddress: String? = nil,
    wanPort: UInt16? = nil
  ) {
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.displayName = displayName
    self.platform = platform
    self.gpuCores = gpuCores
    self.neuralEngineCores = neuralEngineCores
    self.memoryGB = memoryGB
    self.storageAvailableGB = storageAvailableGB
    self.embeddingModel = embeddingModel
    self.embeddingDimensions = embeddingDimensions
    self.indexedRepos = indexedRepos
    self.gitCommitHash = gitCommitHash
    self.lanAddress = lanAddress
    self.lanPort = lanPort
    self.wanAddress = wanAddress
    self.wanPort = wanPort
  }
  
  /// Create capabilities from current device
  public static func current(
    indexedRepos: [String] = [],
    embeddingModel: String? = nil,
    embeddingDimensions: Int? = nil,
    lanAddress: String? = nil,
    lanPort: UInt16? = nil,
    wanAddress: String? = nil,
    wanPort: UInt16? = nil
  ) -> WorkerCapabilities {
    let processInfo = ProcessInfo.processInfo
    
    #if os(macOS)
    let platform = Platform.macOS
    #elseif os(iOS)
    let platform = Platform.iOS
    #elseif os(visionOS)
    let platform = Platform.visionOS
    #else
    let platform = Platform.macOS
    #endif
    
    // Get device ID (persistent across launches)
    let deviceId = Self.getDeviceId()
    
    return WorkerCapabilities(
      deviceId: deviceId,
      deviceName: processInfo.hostName,
      displayName: Self.getConfiguredDisplayName(),
      platform: platform,
      gpuCores: Self.getGPUCores(),
      neuralEngineCores: Self.getNeuralEngineCores(),
      memoryGB: Int(processInfo.physicalMemory / 1_073_741_824), // bytes to GB
      storageAvailableGB: Self.getAvailableStorageGB(),
      embeddingModel: embeddingModel,
      embeddingDimensions: embeddingDimensions,
      indexedRepos: indexedRepos,
      gitCommitHash: Self.getGitCommitHash(),
      lanAddress: lanAddress,
      lanPort: lanPort,
      wanAddress: wanAddress,
      wanPort: wanPort
    )
  }
  
  /// Get the git commit hash embedded at build time
  private static func getGitCommitHash() -> String? {
    // Prefer repo hash for runtime accuracy, then fall back to Info.plist
    if let repoHash = getGitCommitFromRepo(), !repoHash.isEmpty {
      return repoHash
    }
    if let plistHash = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String, !plistHash.isEmpty {
      return plistHash
    }
    return nil
  }
  
  /// Try to get git commit hash from the repository
  private static func getGitCommitFromRepo() -> String? {
    // Find repo path from bundle location
    let bundlePath = Bundle.main.bundlePath
    let components = bundlePath.components(separatedBy: "/")
    
    // Try multiple strategies to find the repo root
    var repoPath: String? = nil
    
    // Strategy 1: Look for "build" folder (standard Xcode project structure)
    if let buildIndex = components.firstIndex(of: "build") {
      repoPath = components.prefix(buildIndex).joined(separator: "/")
    }
    
    // Strategy 2: Look for DerivedData and walk up to find .git
    if repoPath == nil, components.firstIndex(of: "DerivedData") != nil {
      // DerivedData is typically in ~/Library/Developer/Xcode/DerivedData
      // Try common code locations: ~/code/<reponame>
      if let userIndex = components.firstIndex(of: "Users"), userIndex + 1 < components.count {
        let username = components[userIndex + 1]
        let homeDir = "/Users/\(username)"
        // Check common code locations
        for codeDir in ["code", "Code", "Developer", "Projects", "dev"] {
          let potentialPath = "\(homeDir)/\(codeDir)"
          if FileManager.default.fileExists(atPath: potentialPath) {
            // Look for Peel/KitchenSink repo
            for repoName in ["KitchenSink", "kitchen-sink", "Peel", "peel"] {
              let testPath = "\(potentialPath)/\(repoName)"
              if FileManager.default.fileExists(atPath: "\(testPath)/.git") {
                repoPath = testPath
                break
              }
            }
          }
          if repoPath != nil { break }
        }
      }
    }
    
    guard let repoPath = repoPath else { return nil }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--short", "HEAD"]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return output?.isEmpty == false ? output : nil
    } catch {
      return nil
    }
  }

  /// Get custom display name from config file
  /// Config file: ~/Library/Application Support/Peel/worker-config.json
  /// Format: { "displayName": "Supreme Overlord" }
  private static func getConfiguredDisplayName() -> String? {
    guard let data = try? Data(contentsOf: configFilePath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let name = json["displayName"] as? String,
          !name.isEmpty else {
      return nil
    }
    return name
  }
  
  /// Get the config file path
  private static var configFilePath: URL {
    #if os(macOS)
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Peel/worker-config.json")
    #else
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Peel/worker-config.json")
    #endif
  }
  
  /// Save the display name to config file. Pass nil or empty string to clear.
  public static func saveDisplayName(_ name: String?) {
    let configPath = configFilePath
    let configDir = configPath.deletingLastPathComponent()
    
    // Ensure directory exists
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    
    // Read existing config or start fresh
    var config: [String: Any] = [:]
    if let data = try? Data(contentsOf: configPath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      config = existing
    }
    
    // Update displayName
    if let name = name, !name.isEmpty {
      config["displayName"] = name
    } else {
      config.removeValue(forKey: "displayName")
    }
    
    // Write back
    if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
      try? data.write(to: configPath)
    }
  }
  
  /// Get the currently configured display name (public accessor)
  public static func configuredDisplayName() -> String? {
    getConfiguredDisplayName()
  }

  private static func getDeviceId() -> String {
    #if os(macOS)
    // Use hardware UUID on macOS
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(service) }
    
    if let uuidData = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0) {
      return uuidData.takeRetainedValue() as? String ?? UUID().uuidString
    }
    return UUID().uuidString
    #else
    // Use identifierForVendor on iOS
    return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    #endif
  }
  
  private static func getGPUCores() -> Int {
    // This is approximate - Metal doesn't expose exact core count
    // M1: 7-8, M1 Pro: 14-16, M1 Max: 24-32, M1 Ultra: 48-64
    // M2: 8-10, M2 Pro: 16-19, M2 Max: 30-38, M2 Ultra: 60-76
    // For now, return a reasonable default based on memory
    let memoryGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
    switch memoryGB {
    case 0..<16: return 8    // Base chips
    case 16..<32: return 16  // Pro chips
    case 32..<64: return 32  // Max chips
    default: return 64       // Ultra chips
    }
  }
  
  private static func getNeuralEngineCores() -> Int {
    // All Apple Silicon has 16-core ANE
    #if arch(arm64)
    return 16
    #else
    return 0
    #endif
  }
  
  private static func getAvailableStorageGB() -> Int {
    let fileURL = URL(fileURLWithPath: NSHomeDirectory())
    do {
      let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      if let capacity = values.volumeAvailableCapacityForImportantUsage {
        return Int(capacity / 1_073_741_824)
      }
    } catch {
      // Ignore
    }
    return 0
  }
}

// MARK: - Peel Status

// MARK: - RAG Artifact Sync

public enum RAGArtifactSyncDirection: String, Codable, Sendable {
  case push
  case pull
}

public enum RAGArtifactTransferRole: String, Sendable {
  case sender
  case receiver
}

public enum RAGArtifactTransferStatus: String, Sendable {
  case queued
  case preparing
  case transferring
  case applying
  case complete
  case failed
}

public struct RAGArtifactFileInfo: Codable, Sendable {
  public let relativePath: String
  public let sizeBytes: Int
  public let sha256: String
  public let modifiedAt: Date
}

public struct RAGArtifactRepoSnapshot: Codable, Sendable {
  public let repoId: String
  public let name: String
  public let rootPath: String
  public let remoteURL: String?
  public let headSHA: String?
  public let isDirty: Bool
  public let lastCommitAt: Date?
  public let lastIndexedAt: Date?

  public var fingerprint: String {
    let sha = headSHA ?? "unknown"
    return isDirty ? "\(sha)-dirty" : sha
  }
}

public struct RAGArtifactManifest: Codable, Sendable {
  public let formatVersion: Int
  public let version: String
  public let createdAt: Date
  public let schemaVersion: Int
  public let totalBytes: Int
  public let embeddingCacheCount: Int
  public let lastIndexedAt: Date?
  public let files: [RAGArtifactFileInfo]
  public let repos: [RAGArtifactRepoSnapshot]
}

public struct RAGArtifactStatus: Codable, Sendable {
  public let manifestVersion: String
  public let totalBytes: Int
  public let lastSyncedAt: Date?
  public let lastSyncDirection: RAGArtifactSyncDirection?
  public let repoCount: Int
  public let lastIndexedAt: Date?
  public let staleReason: String?
}

public struct RAGArtifactTransferState: Identifiable, Sendable {
  public let id: UUID
  public let peerId: String
  public let peerName: String
  public let direction: RAGArtifactSyncDirection
  public let role: RAGArtifactTransferRole
  public var status: RAGArtifactTransferStatus
  public var totalBytes: Int
  public var transferredBytes: Int
  public var startedAt: Date
  public var completedAt: Date?
  public var errorMessage: String?
  public var manifestVersion: String?

  public var progress: Double {
    guard totalBytes > 0 else { return status == .complete ? 1.0 : 0 }
    return min(1, Double(transferredBytes) / Double(totalBytes))
  }
}

/// Current status of a worker node
public struct WorkerStatus: Codable, Sendable {
  public let deviceId: String
  public let state: WorkerState
  public let currentTaskId: UUID?
  public let lastHeartbeat: Date
  public let uptimeSeconds: TimeInterval
  public let tasksCompleted: Int
  public let tasksFailed: Int
  public let ragArtifacts: RAGArtifactStatus?
  
  public enum WorkerState: String, Codable, Sendable {
    case idle
    case busy
    case offline
    case error
  }
  
  public init(
    deviceId: String,
    state: WorkerState,
    currentTaskId: UUID? = nil,
    lastHeartbeat: Date = Date(),
    uptimeSeconds: TimeInterval = 0,
    tasksCompleted: Int = 0,
    tasksFailed: Int = 0,
    ragArtifacts: RAGArtifactStatus? = nil
  ) {
    self.deviceId = deviceId
    self.state = state
    self.currentTaskId = currentTaskId
    self.lastHeartbeat = lastHeartbeat
    self.uptimeSeconds = uptimeSeconds
    self.tasksCompleted = tasksCompleted
    self.tasksFailed = tasksFailed
    self.ragArtifacts = ragArtifacts
  }
}

// MARK: - Distributed Errors

/// Errors that can occur during distributed task execution
public enum DistributedError: Error, Codable, Sendable {
  case noWorkersAvailable
  case workerNotFound(deviceId: String)
  case connectionFailed(deviceId: String, reason: String)
  case taskClaimFailed(taskId: UUID, reason: String)
  case taskExecutionFailed(taskId: UUID, reason: String)
  case taskTimeout(taskId: UUID)
  case serializationFailed(reason: String)
  case capabilitiesMismatch(required: String, available: String)
  case actorSystemNotReady
  case invalidMessage(reason: String)
}

extension DistributedError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noWorkersAvailable:
      return "No peels are currently available"
    case .workerNotFound(let deviceId):
      return "Peel not found: \(deviceId)"
    case .connectionFailed(let deviceId, let reason):
      return "Connection to \(deviceId) failed: \(reason)"
    case .taskClaimFailed(let taskId, let reason):
      return "Failed to claim task \(taskId): \(reason)"
    case .taskExecutionFailed(let taskId, let reason):
      return "Task \(taskId) execution failed: \(reason)"
    case .taskTimeout(let taskId):
      return "Task \(taskId) timed out"
    case .serializationFailed(let reason):
      return "Serialization failed: \(reason)"
    case .capabilitiesMismatch(let required, let available):
      return "Capabilities mismatch - required: \(required), available: \(available)"
    case .actorSystemNotReady:
      return "Actor system is not ready"
    case .invalidMessage(let reason):
      return "Invalid message: \(reason)"
    }
  }
}

// MARK: - Protocol Messages

/// Messages sent between crown and worker over the wire
public enum PeerMessage: Codable, Sendable {
  case hello(capabilities: WorkerCapabilities)
  case helloAck(capabilities: WorkerCapabilities)
  case heartbeat(status: WorkerStatus)
  case heartbeatAck
  case taskRequest(request: ChainRequest)
  case taskAccepted(taskId: UUID)
  case taskRejected(taskId: UUID, reason: String)
  case taskProgress(taskId: UUID, progress: Double, message: String?)
  case taskResult(result: ChainResult)
  case taskCancel(taskId: UUID)
  case directCommand(id: UUID, command: String, args: [String], workingDirectory: String?)
  case directCommandResult(id: UUID, exitCode: Int32, output: String, error: String?)
  case ragArtifactsRequest(id: UUID, direction: RAGArtifactSyncDirection)
  case ragArtifactsManifest(id: UUID, manifest: RAGArtifactManifest)
  case ragArtifactsChunk(id: UUID, index: Int, total: Int, data: String)
  case ragArtifactsComplete(id: UUID)
  case ragArtifactsError(id: UUID, message: String)
  case goodbye
  
  /// Unique identifier for message type (for logging)
  public var messageType: String {
    switch self {
    case .hello: return "hello"
    case .helloAck: return "helloAck"
    case .heartbeat: return "heartbeat"
    case .heartbeatAck: return "heartbeatAck"
    case .taskRequest: return "taskRequest"
    case .taskAccepted: return "taskAccepted"
    case .taskRejected: return "taskRejected"
    case .taskProgress: return "taskProgress"
    case .taskResult: return "taskResult"
    case .taskCancel: return "taskCancel"
    case .directCommand: return "directCommand"
    case .directCommandResult: return "directCommandResult"
    case .ragArtifactsRequest: return "ragArtifactsRequest"
    case .ragArtifactsManifest: return "ragArtifactsManifest"
    case .ragArtifactsChunk: return "ragArtifactsChunk"
    case .ragArtifactsComplete: return "ragArtifactsComplete"
    case .ragArtifactsError: return "ragArtifactsError"
    case .goodbye: return "goodbye"
    }
  }
}

// MARK: - IOKit Import for macOS

#if os(macOS)
import IOKit
#endif

#if os(iOS)
import UIKit
#endif
