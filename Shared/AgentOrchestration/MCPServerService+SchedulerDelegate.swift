//
//  MCPServerService+SchedulerDelegate.swift
//  Peel
//
//  Conforms MCPServerService to ChainSchedulerDelegate so the scheduler
//  can trigger chain runs through the existing execution pipeline.
//

import Foundation
import os

extension MCPServerService: ChainSchedulerDelegate {

  func schedulerStartChain(
    prompt: String,
    repoPath: String,
    templateId: String?,
    templateName: String?
  ) async throws -> String {
    let result = try await startChain(
      prompt: prompt,
      repoPath: repoPath,
      templateId: templateId,
      templateName: templateName,
      options: ChainToolRunOptions(maxPremiumCost: nil, requireRag: false, skipReview: false, dryRun: false)
    )
    return result.chainId
  }

  func schedulerLog(_ message: String, metadata: [String: String]) {
    logger.info("ChainScheduler: \(message) \(metadata)")
  }
}
