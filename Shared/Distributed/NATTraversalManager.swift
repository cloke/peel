//
//  NATTraversalManager.swift
//  Peel
//
//  Orchestrates NAT traversal for peer-to-peer connections across networks.
//  Uses STUN for endpoint discovery, Firestore for signaling, and UDP hole
//  punching to establish direct connections without router configuration.
//
//  Connection priority:
//    1. LAN (Bonjour/direct TCP) — fastest, zero config
//    2. STUN hole punch → TCP  — works through most NATs
//    3. Firestore relay         — always works, slower
//

import Foundation
import Network
import os.log

// MARK: - NAT Traversal State

/// The current state of a NAT traversal attempt
public enum NATTraversalState: Sendable, CustomStringConvertible {
  case idle
  case discoveringEndpoint
  case waitingForPeer(myEndpoint: STUNResult)
  case punching(myEndpoint: STUNResult, peerEndpoint: PeerEndpoint)
  case connected(method: ConnectionMethod)
  case failed(reason: String)

  public var description: String {
    switch self {
    case .idle: return "idle"
    case .discoveringEndpoint: return "discovering STUN endpoint"
    case .waitingForPeer(let ep): return "waiting for peer (my endpoint: \(ep))"
    case .punching(_, let peer): return "hole punching to \(peer.address):\(peer.port)"
    case .connected(let method): return "connected via \(method)"
    case .failed(let reason): return "failed: \(reason)"
    }
  }
}

/// How the connection was established
public enum ConnectionMethod: String, Sendable {
  case lan = "LAN"
  case holePunchTCP = "hole-punch-TCP"
  case holePunchUDP = "hole-punch-UDP"
  case firestoreRelay = "Firestore-relay"
}

/// A peer's STUN-discovered endpoint stored in Firestore for signaling
public struct PeerEndpoint: Codable, Sendable {
  public let deviceId: String
  public let address: String
  public let port: UInt16
  public let stunServer: String
  public let timestamp: Date

  public init(deviceId: String, address: String, port: UInt16, stunServer: String, timestamp: Date = Date()) {
    self.deviceId = deviceId
    self.address = address
    self.port = port
    self.stunServer = stunServer
    self.timestamp = timestamp
  }
}

// MARK: - NAT Traversal Delegate

@MainActor
public protocol NATTraversalDelegate: AnyObject {
  /// Called when NAT traversal state changes
  func natTraversal(_ manager: NATTraversalManager, didChangeState state: NATTraversalState)
  /// Called when a UDP hole punch succeeds and TCP connection should be attempted
  func natTraversal(_ manager: NATTraversalManager, shouldConnectTCP address: String, port: UInt16)
  /// Called when hole punching fails and Firestore relay should be used
  func natTraversalShouldFallbackToRelay(_ manager: NATTraversalManager, peerId: String)
}

// MARK: - NAT Traversal Manager

/// Manages NAT traversal for establishing P2P connections across networks.
///
/// Flow:
/// 1. Discover our external endpoint via STUN
/// 2. Write our endpoint to Firestore signaling doc
/// 3. Watch for peer's endpoint in Firestore
/// 4. When both endpoints known, simultaneously send UDP probes (hole punching)
/// 5. On success, upgrade to TCP connection
/// 6. On failure, fall back to Firestore relay
@MainActor
public final class NATTraversalManager {
  private let logger = Logger(subsystem: "com.peel.distributed", category: "NATTraversal")

  /// The local UDP port used for hole punching (matches the TCP listener port)
  public let localPort: UInt16

  /// Our device ID
  public let deviceId: String

  /// Current state
  public private(set) var state: NATTraversalState = .idle {
    didSet {
      logger.info("NAT state: \(self.state)")
      delegate?.natTraversal(self, didChangeState: state)
    }
  }

  public weak var delegate: NATTraversalDelegate?

  /// Our STUN-discovered endpoint (cached for reuse)
  public private(set) var stunEndpoint: STUNResult?

  /// Active hole punch sessions by peer device ID
  private var activeSessions: [String: HolePunchSession] = [:]

  /// UDP listener for receiving hole punch probes
  private var udpListener: NWListener?

  /// Peers that have been successfully hole-punched (address confirmed reachable)
  private var punchedPeers: Set<String> = []

  public init(localPort: UInt16 = 8766, deviceId: String) {
    self.localPort = localPort
    self.deviceId = deviceId
  }

  // MARK: - Lifecycle

  /// Discover our STUN endpoint and start the UDP listener for hole punch probes.
  /// Call this once when the swarm starts.
  public func start() async -> STUNResult? {
    state = .discoveringEndpoint

    // Discover our external endpoint
    guard let result = await STUNClient.discoverEndpoint(localPort: localPort) else {
      state = .failed(reason: "Could not discover STUN endpoint")
      return nil
    }

    stunEndpoint = result
    state = .waitingForPeer(myEndpoint: result)

    // Start UDP listener for incoming hole punch probes
    startUDPListener()

    return result
  }

  /// Stop all NAT traversal activity
  public func stop() {
    for (_, session) in activeSessions {
      session.cancel()
    }
    activeSessions.removeAll()
    punchedPeers.removeAll()

    udpListener?.cancel()
    udpListener = nil

    stunEndpoint = nil
    state = .idle
  }

  // MARK: - Hole Punching

  /// Initiate a hole punch to a peer whose STUN endpoint we've learned via Firestore.
  /// Both sides should call this simultaneously for maximum success rate.
  public func punchThrough(to peerEndpoint: PeerEndpoint) async -> Bool {
    guard let myEndpoint = stunEndpoint else {
      logger.warning("Cannot hole punch — no STUN endpoint discovered")
      return false
    }

    // Don't re-punch peers we've already connected to
    guard !punchedPeers.contains(peerEndpoint.deviceId) else {
      logger.debug("Already punched through to \(peerEndpoint.deviceId)")
      return true
    }

    state = .punching(myEndpoint: myEndpoint, peerEndpoint: peerEndpoint)

    let session = HolePunchSession(
      myDeviceId: deviceId,
      peerEndpoint: peerEndpoint,
      localPort: localPort,
      logger: logger
    )
    activeSessions[peerEndpoint.deviceId] = session

    let success = await session.execute()

    activeSessions.removeValue(forKey: peerEndpoint.deviceId)

    if success {
      punchedPeers.insert(peerEndpoint.deviceId)
      state = .connected(method: .holePunchTCP)

      // Tell delegate to attempt TCP now that the NAT binding is open
      delegate?.natTraversal(
        self,
        shouldConnectTCP: peerEndpoint.address,
        port: peerEndpoint.port
      )
      return true
    } else {
      logger.warning("Hole punch failed to \(peerEndpoint.deviceId) — falling back to relay")
      state = .failed(reason: "Hole punch failed to \(peerEndpoint.deviceId)")
      delegate?.natTraversalShouldFallbackToRelay(self, peerId: peerEndpoint.deviceId)
      return false
    }
  }

  /// Check if we've already punched through to a peer
  public func hasPunched(peerId: String) -> Bool {
    punchedPeers.contains(peerId)
  }

  /// Re-discover our STUN endpoint (e.g., after network change)
  public func refreshEndpoint() async -> STUNResult? {
    let result = await STUNClient.discoverEndpoint(localPort: localPort)
    if let result {
      stunEndpoint = result
      logger.info("Refreshed STUN endpoint: \(result)")
    }
    return result
  }

  // MARK: - UDP Listener

  /// Start a UDP listener on our local port to receive hole punch probes.
  /// When we receive a probe from a peer, it confirms our NAT binding is open.
  private func startUDPListener() {
    let params = NWParameters.udp
    if let nwPort = NWEndpoint.Port(rawValue: localPort) {
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: nwPort)
    }

    // Allow port reuse with TCP listener
    params.allowLocalEndpointReuse = true

    do {
      udpListener = try NWListener(using: params)
    } catch {
      logger.error("Failed to create UDP listener: \(error)")
      return
    }

    udpListener?.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        logger.info("UDP hole punch listener ready on port \(self.localPort)")
      case .failed(let error):
        logger.error("UDP listener failed: \(error)")
      default:
        break
      }
    }

    udpListener?.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      self.handleIncomingUDPProbe(connection)
    }

    udpListener?.start(queue: .global(qos: .userInitiated))
  }

  /// Handle an incoming UDP probe from a peer performing hole punching
  private nonisolated func handleIncomingUDPProbe(_ connection: NWConnection) {
    connection.start(queue: .global(qos: .userInitiated))
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let data, error == nil else {
        connection.cancel()
        return
      }

      // Decode the probe
      if let probe = try? JSONDecoder().decode(HolePunchProbe.self, from: data) {
        Task { @MainActor in
          self?.logger.info("Received hole punch probe from \(probe.deviceId)")

          // Send ack back through the same NAT hole
          let ack = HolePunchProbe(
            deviceId: self?.deviceId ?? "",
            type: .ack,
            timestamp: Date()
          )
          if let ackData = try? JSONEncoder().encode(ack) {
            connection.send(content: ackData, completion: .contentProcessed { _ in
              connection.cancel()
            })
          }
        }
      } else {
        connection.cancel()
      }
    }
  }
}

// MARK: - Hole Punch Probe

/// A lightweight UDP probe message for hole punching
struct HolePunchProbe: Codable, Sendable {
  let deviceId: String
  let type: ProbeType
  let timestamp: Date

  enum ProbeType: String, Codable, Sendable {
    case syn    // Initial probe to open NAT binding
    case ack    // Acknowledgment that probe was received
  }
}

// MARK: - Hole Punch Session

/// Manages a single hole punch attempt to a specific peer.
///
/// Strategy (RFC 5765 / ICE-like):
/// 1. Send UDP probes to peer's STUN-discovered endpoint at increasing intervals
/// 2. Listen for probe acks (confirms NAT binding is open in both directions)
/// 3. If ack received within timeout → success, TCP can now connect
/// 4. If timeout → failure, caller should fall back to relay
private final class HolePunchSession: @unchecked Sendable {
  private let myDeviceId: String
  private let peerEndpoint: PeerEndpoint
  private let localPort: UInt16
  private let logger: Logger
  private var connection: NWConnection?
  private var cancelled = false

  /// How many probes to send before giving up
  private let maxProbes = 10
  /// Base interval between probes (increases with each attempt)
  private let probeIntervalMs: UInt64 = 500

  init(
    myDeviceId: String,
    peerEndpoint: PeerEndpoint,
    localPort: UInt16,
    logger: Logger
  ) {
    self.myDeviceId = myDeviceId
    self.peerEndpoint = peerEndpoint
    self.localPort = localPort
    self.logger = logger
  }

  /// Execute the hole punch attempt. Returns true if we received an ack.
  func execute() async -> Bool {
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(peerEndpoint.address),
      port: NWEndpoint.Port(rawValue: peerEndpoint.port)!
    )

    let params = NWParameters.udp
    params.allowLocalEndpointReuse = true
    if let nwPort = NWEndpoint.Port(rawValue: localPort) {
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: nwPort)
    }

    connection = NWConnection(to: endpoint, using: params)

    // Wait for UDP "connection" to be ready
    let ready = await waitForReady()
    guard ready, !cancelled else { return false }

    // Send probes and wait for ack
    return await sendProbesAndWaitForAck()
  }

  func cancel() {
    cancelled = true
    connection?.cancel()
    connection = nil
  }

  private func waitForReady() async -> Bool {
    guard let connection else { return false }

    return await withCheckedContinuation { continuation in
      let resumed = UnsafeSendableBox(value: false)

      connection.stateUpdateHandler = { state in
        guard !resumed.value else { return }

        switch state {
        case .ready:
          guard !resumed.value else { return }
          resumed.value = true
          continuation.resume(returning: true)
        case .failed, .cancelled:
          guard !resumed.value else { return }
          resumed.value = true
          continuation.resume(returning: false)
        default:
          break
        }
      }

      connection.start(queue: .global(qos: .userInitiated))

      // Timeout for connection setup
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        guard !resumed.value else { return }
        resumed.value = true
        continuation.resume(returning: false)
      }
    }
  }

  private func sendProbesAndWaitForAck() async -> Bool {
    guard let connection else { return false }

    let probe = HolePunchProbe(
      deviceId: myDeviceId,
      type: .syn,
      timestamp: Date()
    )
    guard let probeData = try? JSONEncoder().encode(probe) else { return false }

    // Start listening for ack
    let ackReceived = UnsafeSendableBox(value: false)

    // Set up receive before sending
    let receiveTask = Task.detached { [weak self] in
      guard let self, let connection = self.connection else { return }

      connection.receiveMessage { data, _, _, error in
        guard let data, error == nil else { return }
        if let response = try? JSONDecoder().decode(HolePunchProbe.self, from: data),
           response.type == .ack {
          ackReceived.value = true
          self.logger.info("Hole punch ACK received from \(response.deviceId)")
        }
      }
    }

    // Send probes at increasing intervals
    for attempt in 0..<maxProbes {
      guard !cancelled, !ackReceived.value else { break }

      logger.debug("Sending hole punch probe \(attempt + 1)/\(self.maxProbes) to \(self.peerEndpoint.address):\(self.peerEndpoint.port)")

      connection.send(content: probeData, completion: .contentProcessed { _ in })

      // Wait with increasing backoff
      let sleepMs = probeIntervalMs * UInt64(1 + attempt / 3)
      try? await Task.sleep(for: .milliseconds(sleepMs))
    }

    // Give a final moment for the ack to arrive
    if !ackReceived.value {
      try? await Task.sleep(for: .seconds(1))
    }

    receiveTask.cancel()

    let success = ackReceived.value
    connection.cancel()
    self.connection = nil

    return success
  }
}

// MARK: - Thread-safe Box

/// A simple thread-safe mutable box for sharing state across concurrency boundaries
private final class UnsafeSendableBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: T

  init(value: T) { _value = value }

  var value: T {
    get { lock.lock(); defer { lock.unlock() }; return _value }
    set { lock.lock(); defer { lock.unlock() }; _value = newValue }
  }
}
