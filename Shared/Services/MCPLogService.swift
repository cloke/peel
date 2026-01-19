//
//  MCPLogService.swift
//  Peel
//
//  Created on 1/18/26.
//

import Foundation

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