//
//  ChainCheckpointService.swift
//  Peel
//
//  Persists and restores chain state across app restarts.
//  Used by the rebuild-and-continue pipeline to save chain progress
//  before an app rebuild/relaunch, then resume where it left off.
//

import Foundation

/// Serializable snapshot of a chain's progress at a checkpoint.
public struct ChainCheckpoint: Codable, Sendable {
  public let chainId: String
  public let chainName: String
  public let templateName: String
  public let prompt: String
  public let workingDirectory: String?
  public let completedStepIndex: Int
  public let completedResults: [CheckpointResult]
  public let operatorGuidance: [String]
  public let savedAt: Date
  public let reason: String

  public struct CheckpointResult: Codable, Sendable {
    public let agentName: String
    public let model: String
    public let output: String
    public let premiumCost: Double
  }
}

@MainActor
public final class ChainCheckpointService {
  public static let shared = ChainCheckpointService()

  private let fm = FileManager.default

  private var checkpointDir: URL {
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Peel/ChainCheckpoints")
  }

  // MARK: - Save

  /// Save a checkpoint for an active chain.
  public func saveCheckpoint(
    chainId: UUID,
    chainName: String,
    templateName: String,
    prompt: String,
    workingDirectory: String?,
    completedStepIndex: Int,
    results: [(agentName: String, model: String, output: String, premiumCost: Double)],
    operatorGuidance: [String],
    reason: String
  ) throws -> URL {
    try fm.createDirectory(at: checkpointDir, withIntermediateDirectories: true)

    let checkpoint = ChainCheckpoint(
      chainId: chainId.uuidString,
      chainName: chainName,
      templateName: templateName,
      prompt: prompt,
      workingDirectory: workingDirectory,
      completedStepIndex: completedStepIndex,
      completedResults: results.map {
        .init(agentName: $0.agentName, model: $0.model, output: $0.output, premiumCost: $0.premiumCost)
      },
      operatorGuidance: operatorGuidance,
      savedAt: Date(),
      reason: reason
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(checkpoint)

    let filePath = checkpointDir.appendingPathComponent("\(chainId.uuidString).json")
    try data.write(to: filePath, options: .atomic)
    return filePath
  }

  // MARK: - Restore

  /// List all saved checkpoints.
  public func listCheckpoints() -> [ChainCheckpoint] {
    guard let files = try? fm.contentsOfDirectory(at: checkpointDir, includingPropertiesForKeys: nil) else {
      return []
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    return files.compactMap { url -> ChainCheckpoint? in
      guard url.pathExtension == "json" else { return nil }
      guard let data = try? Data(contentsOf: url) else { return nil }
      return try? decoder.decode(ChainCheckpoint.self, from: data)
    }.sorted { $0.savedAt > $1.savedAt }
  }

  /// Load a specific checkpoint by chain ID.
  public func loadCheckpoint(chainId: String) -> ChainCheckpoint? {
    let filePath = checkpointDir.appendingPathComponent("\(chainId).json")
    guard let data = try? Data(contentsOf: filePath) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ChainCheckpoint.self, from: data)
  }

  // MARK: - Cleanup

  /// Remove a checkpoint after successful resume.
  public func removeCheckpoint(chainId: String) {
    let filePath = checkpointDir.appendingPathComponent("\(chainId).json")
    try? fm.removeItem(at: filePath)
  }

  /// Remove all checkpoints older than the given interval.
  public func pruneOldCheckpoints(olderThan interval: TimeInterval = 86400) {
    let cutoff = Date().addingTimeInterval(-interval)
    for checkpoint in listCheckpoints() where checkpoint.savedAt < cutoff {
      removeCheckpoint(chainId: checkpoint.chainId)
    }
  }
}
