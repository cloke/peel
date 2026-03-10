//
//  P2PConnectionLog.swift
//  Peel
//
//  In-memory ring buffer for P2P connection events. Used by both the
//  initiator (OnDemandPeerTransfer) and responder (STUNSignalingResponder)
//  to capture every step of the P2P pipeline with timestamps.
//
//  Can be retrieved remotely via Firestore log requests, enabling
//  cross-network debugging when P2P connections are failing.
//

import Foundation

// MARK: - P2P Connection Log

@MainActor
@Observable
public final class P2PConnectionLog {
  static let shared = P2PConnectionLog()

  struct Entry: Sendable {
    let timestamp: Date
    let category: String
    let event: String
    let details: [String: String]
  }

  private(set) var entries: [Entry] = []
  private let maxEntries = 500

  func log(_ category: String, _ event: String, details: [String: String] = [:]) {
    let entry = Entry(timestamp: Date(), category: category, event: event, details: details)
    entries.append(entry)
    if entries.count > maxEntries {
      entries.removeFirst(entries.count - maxEntries)
    }
  }

  func clear() {
    entries.removeAll()
  }

  func toJSON() -> [[String: Any]] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return entries.map { entry in
      var dict: [String: Any] = [
        "timestamp": formatter.string(from: entry.timestamp),
        "category": entry.category,
        "event": entry.event,
      ]
      if !entry.details.isEmpty {
        dict["details"] = entry.details
      }
      return dict
    }
  }

  /// Serialize entries to a JSON string for Firestore transport.
  func toJSONString() -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: toJSON(), options: [.sortedKeys]),
      let str = String(data: data, encoding: .utf8)
    else { return "[]" }
    return str
  }
}
