// BonjourDiscoveryService.swift
// Peel
//
// Created by Copilot on 2026-01-27.
// Bonjour service for discovering and advertising Peel workers on the LAN.

import Foundation
import Network
import os.log

// MARK: - Discovered Peer

/// A Peel instance discovered on the network
public struct DiscoveredPeer: Identifiable, Sendable {
  public let id: String  // deviceId
  public let name: String
  public let endpoint: NWEndpoint
  public let txtRecord: [String: String]
  public var resolvedAddress: String?
  public var resolvedPort: UInt16?
  
  /// Whether the peer has been resolved to an IP address
  public var isResolved: Bool {
    resolvedAddress != nil && resolvedPort != nil
  }
}

// MARK: - Discovery Delegate

/// Delegate for receiving discovery events
@MainActor
public protocol BonjourDiscoveryDelegate: AnyObject {
  func discoveryService(_ service: BonjourDiscoveryService, didDiscover peer: DiscoveredPeer)
  func discoveryService(_ service: BonjourDiscoveryService, didLose peerId: String)
  func discoveryService(_ service: BonjourDiscoveryService, didResolve peer: DiscoveredPeer)
  func discoveryService(_ service: BonjourDiscoveryService, didFailWithError error: Error)
}

// MARK: - Bonjour Discovery Service

/// Service for discovering and advertising Peel workers via Bonjour/mDNS
@MainActor
public final class BonjourDiscoveryService: @unchecked Sendable {
  
  // MARK: - Constants
  
  /// The Bonjour service type for Peel
  public static let serviceType = "_peel._tcp"
  
  /// Default port for Peel distributed communication
  public static let defaultPort: UInt16 = 8766
  
  // MARK: - Properties
  
  private let logger = Logger(subsystem: "com.peel.distributed", category: "Discovery")
  
  /// Delegate for receiving discovery events
  public weak var delegate: BonjourDiscoveryDelegate?
  
  /// The browser for discovering peers
  private var browser: NWBrowser?
  
  /// The listener for advertising this device
  private var listener: NWListener?
  
  /// Discovered peers by device ID
  public private(set) var discoveredPeers: [String: DiscoveredPeer] = [:]
  
  /// Whether discovery is active
  public private(set) var isDiscovering = false
  
  /// Whether advertising is active
  public private(set) var isAdvertising = false
  
  /// This device's capabilities (for TXT record)
  private var capabilities: WorkerCapabilities?
  
  /// The port we're listening on
  private var advertisedPort: UInt16 = BonjourDiscoveryService.defaultPort
  
  // MARK: - Initialization
  
  public init() {}
  
  // MARK: - Discovery
  
  /// Start discovering Peel workers on the network
  public func startDiscovery() {
    guard !isDiscovering else { return }
    
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    
    browser = NWBrowser(
      for: .bonjour(type: Self.serviceType, domain: nil),
      using: parameters
    )
    
    browser?.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        self?.handleBrowserStateUpdate(state)
      }
    }
    
    browser?.browseResultsChangedHandler = { [weak self] results, changes in
      Task { @MainActor in
        self?.handleBrowseResultsChanged(results: results, changes: changes)
      }
    }
    
    browser?.start(queue: .main)
    isDiscovering = true
    
    logger.info("Started Bonjour discovery for \(Self.serviceType)")
  }
  
  /// Stop discovering peers
  public func stopDiscovery() {
    browser?.cancel()
    browser = nil
    isDiscovering = false
    
    logger.info("Stopped Bonjour discovery")
  }
  
  // MARK: - Advertising
  
  /// Start advertising this device as a Peel worker
  public func startAdvertising(
    capabilities: WorkerCapabilities,
    port: UInt16 = BonjourDiscoveryService.defaultPort
  ) throws {
    guard !isAdvertising else { return }
    
    self.capabilities = capabilities
    self.advertisedPort = port
    
    // Create listener
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    
    listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    
    // Create service with TXT record
    var txtRecord = NWTXTRecord()
    txtRecord["deviceId"] = capabilities.deviceId
    txtRecord["deviceName"] = capabilities.deviceName
    txtRecord["platform"] = capabilities.platform.rawValue
    txtRecord["gpuCores"] = String(capabilities.gpuCores)
    txtRecord["memoryGB"] = String(capabilities.memoryGB)
    
    listener?.service = NWListener.Service(
      name: capabilities.deviceName,
      type: Self.serviceType,
      txtRecord: Data()
    )
    
    listener?.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        self?.handleListenerStateUpdate(state)
      }
    }
    
    listener?.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        self?.handleNewConnection(connection)
      }
    }
    
    listener?.start(queue: .main)
    isAdvertising = true
    
    logger.info("Started advertising as '\(capabilities.deviceName)' on port \(port)")
  }
  
  /// Stop advertising
  public func stopAdvertising() {
    listener?.cancel()
    listener = nil
    isAdvertising = false
    
    logger.info("Stopped advertising")
  }
  
  // MARK: - Resolution
  
  /// Helper class for thread-safe continuation tracking
  private final class ContinuationBox: @unchecked Sendable {
    private var _hasResumed = false
    private let lock = NSLock()
    
    var hasResumed: Bool {
      lock.lock()
      defer { lock.unlock() }
      return _hasResumed
    }
    
    func tryResume() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if _hasResumed { return false }
      _hasResumed = true
      return true
    }
  }
  
  /// Resolve a discovered peer to get its IP address
  public func resolvePeer(_ peerId: String) async throws -> DiscoveredPeer {
    guard let basePeer = discoveredPeers[peerId] else {
      throw DistributedError.workerNotFound(deviceId: peerId)
    }
    
    // Create a connection to resolve the endpoint
    let connection = NWConnection(to: basePeer.endpoint, using: .tcp)
    let endpoint = basePeer.endpoint
    let box = ContinuationBox()
    
    return try await withCheckedThrowingContinuation { continuation in
      connection.stateUpdateHandler = { [weak self, box] state in
        switch state {
        case .ready:
          guard box.tryResume() else { return }
          
          // Get the resolved address
          if let innerEndpoint = connection.currentPath?.remoteEndpoint,
             case let .hostPort(host, port) = innerEndpoint {
            let address: String
            switch host {
            case .ipv4(let ipv4):
              address = "\(ipv4)"
            case .ipv6(let ipv6):
              address = "\(ipv6)"
            case .name(let name, _):
              address = name
            @unknown default:
              address = "unknown"
            }
            
            let resolvedPeer = DiscoveredPeer(
              id: peerId,
              name: basePeer.name,
              endpoint: endpoint,
              txtRecord: basePeer.txtRecord,
              resolvedAddress: address,
              resolvedPort: port.rawValue
            )
            
            Task { @MainActor in
              self?.discoveredPeers[peerId] = resolvedPeer
              if let self = self {
                self.delegate?.discoveryService(self, didResolve: resolvedPeer)
              }
            }
            
            connection.cancel()
            continuation.resume(returning: resolvedPeer)
          }
          
        case .failed(let error):
          guard box.tryResume() else { return }
          connection.cancel()
          continuation.resume(throwing: error)
          
        case .cancelled:
          break
          
        default:
          break
        }
      }
      
      connection.start(queue: .main)
      
      // Timeout after 5 seconds
      Task { [box] in
        try await Task.sleep(for: .seconds(5))
        guard box.tryResume() else { return }
        connection.cancel()
        continuation.resume(throwing: DistributedError.connectionFailed(
          deviceId: peerId,
          reason: "Resolution timeout"
        ))
      }
    }
  }
  
  // MARK: - State Handlers
  
  private func handleBrowserStateUpdate(_ state: NWBrowser.State) {
    switch state {
    case .ready:
      logger.info("Browser ready")
      
    case .failed(let error):
      logger.error("Browser failed: \(error)")
      delegate?.discoveryService(self, didFailWithError: error)
      
    case .cancelled:
      logger.info("Browser cancelled")
      
    default:
      break
    }
  }
  
  private func handleBrowseResultsChanged(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
    for change in changes {
      switch change {
      case .added(let result):
        handlePeerAdded(result)
        
      case .removed(let result):
        handlePeerRemoved(result)
        
      case .changed(old: _, new: let newResult, flags: _):
        handlePeerChanged(newResult)
        
      case .identical:
        break
        
      @unknown default:
        break
      }
    }
  }
  
  private func handlePeerAdded(_ result: NWBrowser.Result) {
    // Parse TXT record
    let txtDict: [String: String] = [:]
    if case .bonjour(_) = result.metadata {
      // NWTXTRecord doesn't have direct iteration, parse manually
      // For now, we'll get deviceId from service name
    }
    
    // Get device ID from endpoint or generate one
    let deviceId: String
    let serviceName: String
    
    if case let .service(name, _, _, _) = result.endpoint {
      serviceName = name
      deviceId = name // Use service name as device ID for now
    } else {
      serviceName = "Unknown"
      deviceId = UUID().uuidString
    }
    
    // Skip if it's ourselves
    if let myCapabilities = capabilities, deviceId == myCapabilities.deviceId {
      return
    }
    
    let peer = DiscoveredPeer(
      id: deviceId,
      name: serviceName,
      endpoint: result.endpoint,
      txtRecord: txtDict
    )
    
    discoveredPeers[deviceId] = peer
    delegate?.discoveryService(self, didDiscover: peer)
    
    logger.info("Discovered peer: \(serviceName)")
  }
  
  private func handlePeerRemoved(_ result: NWBrowser.Result) {
    if case let .service(name, _, _, _) = result.endpoint {
      if discoveredPeers.removeValue(forKey: name) != nil {
        delegate?.discoveryService(self, didLose: name)
        logger.info("Lost peer: \(name)")
      }
    }
  }
  
  private func handlePeerChanged(_ result: NWBrowser.Result) {
    // Re-add with updated info
    handlePeerAdded(result)
  }
  
  private func handleListenerStateUpdate(_ state: NWListener.State) {
    switch state {
    case .ready:
      if let port = listener?.port {
        logger.info("Listener ready on port \(port.rawValue)")
      }
      
    case .failed(let error):
      logger.error("Listener failed: \(error)")
      delegate?.discoveryService(self, didFailWithError: error)
      
    case .cancelled:
      logger.info("Listener cancelled")
      
    default:
      break
    }
  }
  
  private func handleNewConnection(_ connection: NWConnection) {
    logger.info("New incoming connection")
    
    // Accept the connection and handle it
    // This will be wired up to the LocalNetworkActorSystem
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.logger.info("Connection ready")
        // TODO: Hand off to actor system
        
      case .failed(let error):
        self?.logger.error("Connection failed: \(error)")
        
      default:
        break
      }
    }
    
    connection.start(queue: .main)
  }
}


