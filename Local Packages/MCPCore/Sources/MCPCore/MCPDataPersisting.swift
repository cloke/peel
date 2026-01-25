//
//  MCPDataPersisting.swift
//  MCPCore
//
//  Protocol for abstracting data persistence from MCP server.
//

import Foundation

// MARK: - MCP Data Persisting Protocol

/// Protocol for persisting MCP run data (implemented by app with SwiftData)
@MainActor
public protocol MCPDataPersisting: Sendable {
  /// Save a new run record
  func saveRunRecord(_ record: MCPRunRecordDTO) async throws

  /// Update an existing run record
  func updateRunRecord(_ record: MCPRunRecordDTO) async throws

  /// Get a run record by chain ID
  func getRunRecord(forChainId chainId: String) async -> MCPRunRecordDTO?

  /// Get recent run records
  func getRecentRuns(limit: Int) async -> [MCPRunRecordDTO]

  /// Save a run result
  func saveRunResult(_ result: MCPRunResultDTO) async throws

  /// Get results for a chain
  func getResults(forChainId chainId: String) async -> [MCPRunResultDTO]

  /// Delete old records (cleanup)
  func deleteOldRecords(olderThan date: Date) async throws
}

// MARK: - Default Implementation (No-op)

/// Default no-op implementation for testing or when persistence is disabled
public final class MCPNullDataStore: MCPDataPersisting, @unchecked Sendable {
  public init() {}

  public func saveRunRecord(_ record: MCPRunRecordDTO) async throws {}
  public func updateRunRecord(_ record: MCPRunRecordDTO) async throws {}
  public func getRunRecord(forChainId chainId: String) async -> MCPRunRecordDTO? { nil }
  public func getRecentRuns(limit: Int) async -> [MCPRunRecordDTO] { [] }
  public func saveRunResult(_ result: MCPRunResultDTO) async throws {}
  public func getResults(forChainId chainId: String) async -> [MCPRunResultDTO] { [] }
  public func deleteOldRecords(olderThan date: Date) async throws {}
}
