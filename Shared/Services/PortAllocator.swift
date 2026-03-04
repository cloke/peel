//
//  PortAllocator.swift
//  Peel
//
//  Simple port allocator for parallel UX testing sessions.
//  Manages dev server ports and Chrome debug ports.
//

import Foundation

/// Allocates unique ports for parallel browser sessions.
/// Thread-safe via actor isolation.
actor PortAllocator {
  /// Port range configuration
  struct PortRange: Sendable {
    let start: UInt16
    let end: UInt16

    var count: Int { Int(end - start) + 1 }

    func contains(_ port: UInt16) -> Bool {
      port >= start && port <= end
    }
  }

  /// Default port ranges (supports up to 50 parallel sessions)
  static let defaultDevServerRange = PortRange(start: 3001, end: 3050)
  static let defaultChromeDebugRange = PortRange(start: 9222, end: 9271)

  private let devServerRange: PortRange
  private let chromeDebugRange: PortRange

  /// Maps session ID → allocated dev server port
  private var devServerPorts: [UUID: UInt16] = [:]
  /// Maps session ID → allocated Chrome debug port
  private var chromeDebugPorts: [UUID: UInt16] = [:]

  init(
    devServerRange: PortRange = defaultDevServerRange,
    chromeDebugRange: PortRange = defaultChromeDebugRange
  ) {
    self.devServerRange = devServerRange
    self.chromeDebugRange = chromeDebugRange
  }

  /// Allocate both a dev server port and Chrome debug port for a session.
  /// - Parameter sessionId: Unique session identifier (typically execution ID)
  /// - Returns: Tuple of (devServerPort, chromeDebugPort)
  /// - Throws: If no ports are available
  func allocate(for sessionId: UUID) throws -> (devPort: UInt16, chromePort: UInt16) {
    let usedDev = Set(devServerPorts.values)
    let usedChrome = Set(chromeDebugPorts.values)

    guard let devPort = nextAvailable(in: devServerRange, excluding: usedDev) else {
      throw PortAllocatorError.noDevPortsAvailable
    }
    guard let chromePort = nextAvailable(in: chromeDebugRange, excluding: usedChrome) else {
      throw PortAllocatorError.noChromePortsAvailable
    }

    devServerPorts[sessionId] = devPort
    chromeDebugPorts[sessionId] = chromePort
    return (devPort, chromePort)
  }

  /// Release ports for a session.
  func release(for sessionId: UUID) {
    devServerPorts.removeValue(forKey: sessionId)
    chromeDebugPorts.removeValue(forKey: sessionId)
  }

  /// Get the dev server port for a session.
  func devPort(for sessionId: UUID) -> UInt16? {
    devServerPorts[sessionId]
  }

  /// Get the Chrome debug port for a session.
  func chromePort(for sessionId: UUID) -> UInt16? {
    chromeDebugPorts[sessionId]
  }

  /// Get all active sessions with their ports.
  func activeSessions() -> [(sessionId: UUID, devPort: UInt16, chromePort: UInt16)] {
    devServerPorts.compactMap { sessionId, devPort in
      guard let chromePort = chromeDebugPorts[sessionId] else { return nil }
      return (sessionId, devPort, chromePort)
    }
  }

  /// Number of active sessions.
  var activeCount: Int {
    devServerPorts.count
  }

  // MARK: - Private

  private func nextAvailable(in range: PortRange, excluding used: Set<UInt16>) -> UInt16? {
    for port in range.start...range.end {
      if !used.contains(port) {
        return port
      }
    }
    return nil
  }
}

// MARK: - Errors

enum PortAllocatorError: LocalizedError {
  case noDevPortsAvailable
  case noChromePortsAvailable

  var errorDescription: String? {
    switch self {
    case .noDevPortsAvailable:
      return "No dev server ports available (range exhausted)"
    case .noChromePortsAvailable:
      return "No Chrome debug ports available (range exhausted)"
    }
  }
}
