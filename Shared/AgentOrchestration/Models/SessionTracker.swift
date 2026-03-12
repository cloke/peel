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
  
  public init() {}
  
  /// Record a completed chain run
  public func recordChainRun(_ chain: AgentChain) {
    let premiumCost = chain.results.reduce(0.0) { $0 + $1.premiumCost }
    let freeCost = chain.results.filter { result in
      result.model.lowercased().contains("free")
    }.count
    
    totalPremiumUsed += premiumCost
    totalFreeUsed += freeCost
  }
  
  /// Reset the session (e.g., at start of new day)
  public func resetSession() {
    sessionStartTime = Date()
    totalPremiumUsed = 0.0
    totalFreeUsed = 0
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
  
}
