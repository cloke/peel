//
//  SessionTracker.swift
//  KitchenSync
//
//  Created on 1/9/26.
//

import Foundation

/// Tracks usage and costs across an agent session
@MainActor
@Observable
public final class SessionTracker {
  
  /// When the current session started
  public private(set) var sessionStartTime: Date = Date()
  
  /// Total premium requests used this session
  public private(set) var totalPremiumUsed: Double = 0.0
  
  /// Total free requests used this session
  public private(set) var totalFreeUsed: Int = 0
  
  /// History of all chain runs this session
  public private(set) var chainRunHistory: [ChainRunRecord] = []
  
  public init() {}
  
  /// Record a completed chain run
  public func recordChainRun(_ chain: AgentChain) {
    let premiumCost = chain.results.reduce(0.0) { $0 + $1.premiumCost }
    let freeCost = chain.results.filter { result in
      // Check if the model was free (GPT-4.1 Free is the only free option currently)
      result.model.lowercased().contains("free")
    }.count
    
    let record = ChainRunRecord(
      chainId: chain.id,
      chainName: chain.name,
      results: chain.results,
      totalPremium: premiumCost,
      totalFree: freeCost,
      timestamp: Date()
    )
    
    chainRunHistory.append(record)
    totalPremiumUsed += premiumCost
    totalFreeUsed += freeCost
  }
  
  /// Reset the session (e.g., at start of new day)
  public func resetSession() {
    sessionStartTime = Date()
    totalPremiumUsed = 0.0
    totalFreeUsed = 0
    chainRunHistory = []
  }
  
  /// Session duration as formatted string
  public var sessionDuration: String {
    let elapsed = Date().timeIntervalSince(sessionStartTime)
    let hours = Int(elapsed) / 3600
    let minutes = (Int(elapsed) % 3600) / 60
    
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    } else {
      return "\(minutes)m"
    }
  }
  
  /// Export all chain runs as markdown
  public func exportAsMarkdown() -> String {
    var markdown = """
    # Agent Session Report
    
    **Session Started:** \(sessionStartTime.formatted(date: .abbreviated, time: .shortened))
    **Duration:** \(sessionDuration)
    **Total Premium Requests:** \(totalPremiumUsed.premiumMultiplierString())
    **Total Free Requests:** \(totalFreeUsed)
    **Total Chain Runs:** \(chainRunHistory.count)
    
    ---
    
    """
    
    for (index, record) in chainRunHistory.enumerated() {
      markdown += """
      
      ## Run \(index + 1): \(record.chainName)
      
      **Time:** \(record.timestamp.formatted(date: .omitted, time: .shortened))
      **Premium Used:** \(record.totalPremium.premiumMultiplierString())
      
      """
      
      for result in record.results {
        markdown += """
        
        ### \(result.agentName) (\(result.model))
        
        **Duration:** \(result.duration ?? "N/A")
        **Premium Cost:** \(result.premiumCost.premiumMultiplierString())
        
        #### Prompt
        ```
        \(result.prompt)
        ```
        
        #### Output
        \(result.output)
        
        ---
        
        """
      }
    }
    
    return markdown
  }
}

/// Record of a single chain run
public struct ChainRunRecord: Identifiable {
  public let id: UUID
  public let chainId: UUID
  public let chainName: String
  public let results: [AgentChainResult]
  public let totalPremium: Double
  public let totalFree: Int
  public let timestamp: Date
  
  public init(
    chainId: UUID,
    chainName: String,
    results: [AgentChainResult],
    totalPremium: Double,
    totalFree: Int,
    timestamp: Date
  ) {
    self.id = UUID()
    self.chainId = chainId
    self.chainName = chainName
    self.results = results
    self.totalPremium = totalPremium
    self.totalFree = totalFree
    self.timestamp = timestamp
  }
}
