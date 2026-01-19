//
//  MCPLogService.swift
//  Peel
//
//  Created on 1/18/26.
//

import Foundation

struct MCPLogEntry: Sendable {
  let timestamp: Date
  let level: String
  let message: String
  let metadata: [String: String]
}

actor MCPLogService {
  static let shared = MCPLogService()

  private let fileURL: URL
  private let formatter = ISO8601DateFormatter()

  private init() {
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let logsURL = baseURL.appendingPathComponent("Peel/Logs", isDirectory: true)
    if !FileManager.default.fileExists(atPath: logsURL.path) {
      try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
    }
    self.fileURL = logsURL.appendingPathComponent("mcp.log")
  }

  func logPath() -> String {
    fileURL.path
  }

  func info(_ message: String, metadata: [String: String] = [:]) {
    write(level: "INFO", message: message, metadata: metadata)
  }

  func warning(_ message: String, metadata: [String: String] = [:]) {
    write(level: "WARN", message: message, metadata: metadata)
  }

  func error(_ message: String, metadata: [String: String] = [:]) {
    write(level: "ERROR", message: message, metadata: metadata)
  }

  func error(_ error: Error, context: String, metadata: [String: String] = [:]) {
    write(level: "ERROR", message: "\(context): \(error.localizedDescription)", metadata: metadata)
  }

  func tail(lines: Int = 200) -> String {
    guard let data = try? Data(contentsOf: fileURL),
          let text = String(data: data, encoding: .utf8) else {
      return ""
    }
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
    let slice = parts.suffix(max(1, lines))
    return slice.joined(separator: "\n")
  }

  func readEntries(limit: Int = 1000) -> [MCPLogEntry] {
    guard let data = try? Data(contentsOf: fileURL),
          let text = String(data: data, encoding: .utf8) else {
      return []
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    let slice = lines.suffix(max(1, limit))
    var entries: [MCPLogEntry] = []
    entries.reserveCapacity(slice.count)

    for line in slice {
      let sections = line.split(separator: "]", maxSplits: 2, omittingEmptySubsequences: false)
      guard sections.count >= 3 else { continue }
      let timestampText = sections[0].dropFirst()
      let levelText = sections[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedLevel = levelText.hasPrefix("[") ? String(levelText.dropFirst()) : levelText
      let remainder = sections[2].trimmingCharacters(in: .whitespacesAndNewlines)

      let parts = remainder.components(separatedBy: " | ")
      let message = parts.first ?? ""
      var metadata: [String: String] = [:]
      if parts.count > 1 {
        for pair in parts[1].split(separator: " ") {
          let kv = pair.split(separator: "=", maxSplits: 1)
          if kv.count == 2 {
            metadata[String(kv[0])] = String(kv[1])
          }
        }
      }

      if let timestamp = formatter.date(from: String(timestampText)) {
        entries.append(
          MCPLogEntry(
            timestamp: timestamp,
            level: trimmedLevel,
            message: message,
            metadata: metadata
          )
        )
      }
    }

    return entries
  }

  private func write(level: String, message: String, metadata: [String: String]) {
    let timestamp = formatter.string(from: Date())
    let metadataText = metadata.isEmpty
      ? ""
      : " | " + metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    let line = "[\(timestamp)] [\(level)] \(message)\(metadataText)\n"

    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    guard let data = line.data(using: .utf8),
          let handle = try? FileHandle(forWritingTo: fileURL) else {
      return
    }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      return
    }
    try? handle.close()
  }
}