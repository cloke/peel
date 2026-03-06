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
  
  /// Custom display name from TXT record, or falls back to name
  public var displayName: String {
    txtRecord["displayName"] ?? name
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
  
  /// NetService for Bonjour advertising (doesn't require binding a port)
  private var netService: NetService?
  
  /// NetService delegate wrapper
  private lazy var netServiceDelegate = NetServiceDelegateWrapper(parent: self)
  
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
  /// Note: This only registers with Bonjour/mDNS. The actual TCP listener
  /// is managed by PeerConnectionManager.
  public func startAdvertising(
    capabilities: WorkerCapabilities,
    port: UInt16 = BonjourDiscoveryService.defaultPort
  ) throws {
    guard !isAdvertising else { return }
    
    self.capabilities = capabilities
    self.advertisedPort = port
    
    // Use NetService for Bonjour advertising (doesn't require binding a port)
    let netService = NetService(
      domain: "",
      type: Self.serviceType,
      name: capabilities.deviceName,
      port: Int32(port)
    )
    
    // Create TXT record data
    var txtDict: [String: Data] = [:]
    txtDict["deviceId"] = capabilities.deviceId.data(using: .utf8)
    txtDict["deviceName"] = capabilities.deviceName.data(using: .utf8)
    txtDict["platform"] = capabilities.platform.rawValue.data(using: .utf8)
    txtDict["gpuCores"] = String(capabilities.gpuCores).data(using: .utf8)
    txtDict["memoryGB"] = String(capabilities.memoryGB).data(using: .utf8)
    if let displayName = capabilities.displayName {
      txtDict["displayName"] = displayName.data(using: .utf8)
    }
    
    let txtData = NetService.data(fromTXTRecord: txtDict)
    netService.setTXTRecord(txtData)
    
    // Store and publish
    self.netService = netService
    netService.delegate = netServiceDelegate
    netService.publish()
    
    isAdvertising = true
    
    logger.info("Started advertising as '\(capabilities.deviceName)' on port \(port)")
  }
  
  /// Stop advertising
  public func stopAdvertising() {
    netService?.stop()
    netService = nil
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
    // Get service name from endpoint
    let serviceName: String
    if case let .service(name, _, _, _) = result.endpoint {
      serviceName = name
    } else {
      serviceName = "Unknown"
    }
    
    // Parse TXT record to get deviceId
    var txtDict: [String: String] = [:]
    var deviceId: String = serviceName  // fallback to service name
    
    if case let .bonjour(txtRecord) = result.metadata {
      // Parse NWTXTRecord - dictionary is [String: String]
      txtDict = txtRecord.dictionary
      // Use deviceId from TXT record if present
      if let recordedDeviceId = txtDict["deviceId"], !recordedDeviceId.isEmpty {
        deviceId = recordedDeviceId
        // Clean up any stale entry stored under the service name —
        // initial browse results often lack TXT records, so we store
        // under the service name first. Once the real deviceId arrives
        // (via a .changed event), remove the old entry to prevent ghosts.
        if serviceName != deviceId {
          if discoveredPeers.removeValue(forKey: serviceName) != nil {
            logger.debug("Cleaned up stale discovery entry for \(serviceName) (now keyed by \(deviceId))")
          }
        }
      }
    }
    
    // Skip if it's ourselves (compare by deviceId)
    if let myCapabilities = capabilities, deviceId == myCapabilities.deviceId {
      logger.debug("Skipping self-discovery: \(serviceName)")
      return
    }
    
    // Also skip if the service name matches our device name (backup check)
    if let myCapabilities = capabilities, serviceName == myCapabilities.deviceName {
      logger.debug("Skipping self-discovery by name: \(serviceName)")
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
    
    logger.info("Discovered peer: \(serviceName) (deviceId: \(deviceId))")
  }
  
  private func handlePeerRemoved(_ result: NWBrowser.Result) {
    // Get deviceId from TXT record if available, otherwise use service name
    var deviceId: String? = nil
    
    if case let .bonjour(txtRecord) = result.metadata {
      let txtDict = txtRecord.dictionary
      if let recordedDeviceId = txtDict["deviceId"], !recordedDeviceId.isEmpty {
        deviceId = recordedDeviceId
      }
    }
    
    // If we don't have deviceId from TXT, try to find by service name
    if deviceId == nil, case let .service(name, _, _, _) = result.endpoint {
      // Look for a peer with matching name
      for (key, peer) in discoveredPeers {
        if peer.name == name {
          deviceId = key
          break
        }
      }
    }
    
    if let deviceId = deviceId, discoveredPeers.removeValue(forKey: deviceId) != nil {
      delegate?.discoveryService(self, didLose: deviceId)
      logger.info("Lost peer: \(deviceId)")
    }
  }
  
  private func handlePeerChanged(_ result: NWBrowser.Result) {
    // Re-add with updated info
    handlePeerAdded(result)
  }
  
  // MARK: - NetService Delegate Handling
  
  fileprivate func handleNetServiceDidPublish(_ serviceName: String) {
    logger.info("NetService published: \(serviceName)")
  }
  
  fileprivate func handleNetServiceDidNotPublish(_ serviceName: String, error: [String: NSNumber]) {
    logger.error("NetService publish failed for \(serviceName): \(error)")
    let nsError = NSError(domain: "BonjourDiscovery", code: error[NetService.errorCode]?.intValue ?? -1, userInfo: nil)
    delegate?.discoveryService(self, didFailWithError: nsError)
  }
}

// MARK: - NetService Delegate Wrapper

/// Wrapper to handle NetService delegate callbacks (NSObject requirement)
private final class NetServiceDelegateWrapper: NSObject, NetServiceDelegate, @unchecked Sendable {
  weak var parent: BonjourDiscoveryService?
  
  init(parent: BonjourDiscoveryService) {
    self.parent = parent
  }
  
  func netServiceDidPublish(_ sender: NetService) {
    let serviceName = sender.name
    Task { @MainActor [weak self] in
      self?.parent?.handleNetServiceDidPublish(serviceName)
    }
  }
  
  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    let serviceName = sender.name
    Task { @MainActor [weak self] in
      self?.parent?.handleNetServiceDidNotPublish(serviceName, error: errorDict)
    }
  }
}


