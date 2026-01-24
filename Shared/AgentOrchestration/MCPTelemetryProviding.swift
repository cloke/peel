//
//  MCPTelemetryProviding.swift
//  Peel
//
//  Created on 1/22/26.
//

import Foundation
@MainActor
public protocol MCPTelemetryProviding: AnyObject {
  func info(_ message: String, metadata: [String: String]) async
  func warning(_ message: String, metadata: [String: String]) async
  func error(_ message: String, metadata: [String: String]) async
  func error(_ error: Error, context: String, metadata: [String: String]) async
  func logPath() async -> String
  func tail(lines: Int) async -> String
  func recordChainRun(_ chain: Any)
  var totalPremiumUsed: Double { get }
  var totalFreeUsed: Int { get }
}


