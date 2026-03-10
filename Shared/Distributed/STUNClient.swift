//
//  STUNClient.swift
//  Peel
//
//  Lightweight STUN client (RFC 5389) for NAT traversal.
//  Queries public STUN servers to discover the device's external
//  IP:port mapping as seen from outside the NAT.
//

import Foundation
import Network
import os.log

// MARK: - STUN Result

/// The external (server-reflexive) address discovered via STUN
public struct STUNResult: Sendable, CustomStringConvertible {
  public let address: String
  public let port: UInt16
  public let serverUsed: String
  public let latencyMs: Int

  public var description: String {
    "\(address):\(port) (via \(serverUsed), \(latencyMs)ms)"
  }
}

// MARK: - STUN Client

/// Discovers NAT-mapped external endpoints using the STUN protocol (RFC 5389).
/// Uses UDP to query public STUN servers — the response tells us our public IP:port.
public enum STUNClient {
  private static let logger = Logger(subsystem: "com.peel.distributed", category: "STUN")

  /// Well-known free STUN servers
  private static let stunServers: [(host: String, port: UInt16)] = [
    ("stun.l.google.com", 19302),
    ("stun1.l.google.com", 19302),
    ("stun.cloudflare.com", 3478),
    ("stun2.l.google.com", 19302),
  ]

  // MARK: - STUN Message Constants (RFC 5389)

  /// STUN message types
  private static let bindingRequest: UInt16 = 0x0001
  private static let bindingResponse: UInt16 = 0x0101

  /// STUN magic cookie (RFC 5389 §6)
  private static let magicCookie: UInt32 = 0x2112A442

  /// STUN attribute types
  private static let attrMappedAddress: UInt16 = 0x0001
  private static let attrXorMappedAddress: UInt16 = 0x0020

  // MARK: - Public API

  /// Discover our external endpoint by querying STUN servers.
  /// Tries each server in order until one responds.
  /// - Parameters:
  ///   - localPort: The local UDP port to bind (should match the port you'll use for hole punching)
  ///   - timeout: Timeout per server attempt in seconds
  /// - Returns: The discovered external endpoint, or nil if all servers failed
  public static func discoverEndpoint(
    localPort: UInt16 = 0,
    timeout: TimeInterval = 3
  ) async -> STUNResult? {
    let p2pLog = await P2PConnectionLog.shared
    await p2pLog.log("stun-client", "discoverEndpoint starting", details: [
      "localPort": String(localPort),
      "timeout": "\(timeout)s",
      "serverCount": String(stunServers.count),
    ])
    // First pass: try with the requested local port
    for (index, server) in stunServers.enumerated() {
      if let result = await queryServer(
        host: server.host,
        port: server.port,
        localPort: localPort,
        timeout: timeout
      ) {
        await p2pLog.log("stun-client", "discoverEndpoint OK", details: [
          "server": "\(server.host):\(server.port)",
          "externalAddress": result.address,
          "externalPort": String(result.port),
          "latencyMs": String(result.latencyMs),
          "serverIndex": String(index),
        ])
        return result
      }
      await p2pLog.log("stun-client", "Server \(index) failed", details: [
        "server": "\(server.host):\(server.port)",
        "localPort": String(localPort),
      ])
      logger.warning("STUN: \(server.host):\(server.port) failed (localPort=\(localPort)), trying next")
    }

    // Do NOT fall back to an ephemeral port. STUN discovery must use the same
    // local port that TCP simultaneous open will bind to (typically 8766). If we
    // discover an endpoint on a random ephemeral port, the NAT mapping won't match
    // the TCP source port, and hole-punching will silently fail.
    await p2pLog.log("stun-client", "ALL servers failed", details: [
      "localPort": String(localPort),
      "timeout": "\(timeout)s",
    ])
    logger.error("STUN: all \(stunServers.count) servers failed (timeout=\(timeout)s, localPort=\(localPort)). Ensure UDP port \(localPort) is not blocked by endpoint security software.")
    return nil
  }

  /// Query a single STUN server
  public static func queryServer(
    host: String,
    port: UInt16,
    localPort: UInt16 = 0,
    timeout: TimeInterval = 3
  ) async -> STUNResult? {
    let startTime = ContinuousClock.now

    // Build STUN Binding Request
    let transactionId = generateTransactionId()
    let request = buildBindingRequest(transactionId: transactionId)

    // Create UDP connection
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!
    )

    let params = NWParameters.udp
    params.allowLocalEndpointReuse = true
    // Force IPv4 — the P2P system uses IPv4 addresses, and STUN servers
    // return IPv6 XOR-MAPPED-ADDRESS when queried over IPv6, which we
    // can't use for NAT traversal coordination.
    if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      ipOptions.version = .v4
    }
    // Bind to specific local port if requested (so the STUN response
    // tells us the mapping for the port we'll actually use)
    if localPort > 0, let nwPort = NWEndpoint.Port(rawValue: localPort) {
      params.requiredLocalEndpoint = NWEndpoint.hostPort(
        host: .ipv4(.any),
        port: nwPort
      )
    }

    let connection = NWConnection(to: endpoint, using: params)

    return await withCheckedContinuation { continuation in
      let box = STUNContinuationBox(
        connection: connection,
        continuation: continuation
      )

      // Timeout
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        box.resume(with: nil)
      }

      connection.stateUpdateHandler = { [box] state in
        switch state {
        case .setup:
          break

        case .preparing:
          logger.debug("STUN: connection preparing to \(host):\(port)")

        case .waiting(let error):
          logger.warning("STUN: connection waiting for \(host):\(port): \(error)")
          // .waiting means Network.framework can't find a usable path —
          // often caused by endpoint security or content filters blocking UDP.
          box.resume(with: nil)

        case .ready:
          // Send STUN Binding Request
          connection.send(
            content: request,
            completion: .contentProcessed { [box] error in
              if let error {
                logger.debug("STUN send failed to \(host): \(error)")
                box.resume(with: nil)
                return
              }

              // Receive response
              connection.receiveMessage { [box] data, _, _, error in
                if let error {
                  logger.debug("STUN receive failed from \(host): \(error)")
                }
                guard let data, error == nil else {
                  box.resume(with: nil)
                  return
                }

                let elapsed = ContinuousClock.now - startTime
                let latencyMs = Int(elapsed.components.seconds * 1000
                  + elapsed.components.attoseconds / 1_000_000_000_000_000)

                if let (address, mappedPort) = parseBindingResponse(
                  data: data, transactionId: transactionId
                ) {
                  let result = STUNResult(
                    address: address,
                    port: mappedPort,
                    serverUsed: host,
                    latencyMs: latencyMs
                  )
                  logger.info("STUN discovered: \(result)")
                  box.resume(with: result)
                } else {
                  logger.warning("STUN: failed to parse \(data.count)-byte response from \(host):\(port)")
                  box.resume(with: nil)
                }
              }
            }
          )

        case .failed(let error):
          logger.warning("STUN: connection failed to \(host):\(port): \(error)")
          box.resume(with: nil)

        case .cancelled:
          box.resume(with: nil)

        @unknown default:
          break
        }
      }

      connection.start(queue: .global(qos: .userInitiated))
    }
  }

  // MARK: - Continuation Box

  /// Thread-safe box for resuming a STUN continuation exactly once
  private final class STUNContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<STUNResult?, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<STUNResult?, Never>) {
      self.connection = connection
      self.continuation = continuation
    }

    func resume(with result: STUNResult?) {
      lock.lock()
      defer { lock.unlock() }
      guard !hasResumed else { return }
      hasResumed = true
      connection.cancel()
      continuation.resume(returning: result)
    }
  }

  // MARK: - STUN Protocol

  /// Generate a random 12-byte transaction ID
  private static func generateTransactionId() -> Data {
    var bytes = [UInt8](repeating: 0, count: 12)
    for i in 0..<12 {
      bytes[i] = UInt8.random(in: 0...255)
    }
    return Data(bytes)
  }

  /// Build a STUN Binding Request message (RFC 5389 §6)
  ///
  /// Format:
  ///   0                   1                   2                   3
  ///   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  ///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  ///  |0 0|     STUN Message Type     |         Message Length        |
  ///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  ///  |                         Magic Cookie                         |
  ///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  ///  |                                                               |
  ///  |                     Transaction ID (96 bits)                  |
  ///  |                                                               |
  ///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  private static func buildBindingRequest(transactionId: Data) -> Data {
    var data = Data(capacity: 20)

    // Message type: Binding Request (0x0001)
    var msgType = bindingRequest.bigEndian
    data.append(Data(bytes: &msgType, count: 2))

    // Message length: 0 (no attributes in request)
    var msgLength: UInt16 = 0
    data.append(Data(bytes: &msgLength, count: 2))

    // Magic cookie
    var cookie = magicCookie.bigEndian
    data.append(Data(bytes: &cookie, count: 4))

    // Transaction ID (12 bytes)
    data.append(transactionId)

    return data
  }

  /// Parse a STUN Binding Response, extracting the mapped address.
  /// Supports both XOR-MAPPED-ADDRESS (preferred) and MAPPED-ADDRESS.
  private static func parseBindingResponse(
    data: Data,
    transactionId: Data
  ) -> (String, UInt16)? {
    guard data.count >= 20 else { return nil }

    // Verify message type is Binding Response
    let msgType = data.readUInt16(at: 0)
    guard msgType == bindingResponse else { return nil }

    // Verify magic cookie
    let cookie = data.readUInt32(at: 4)
    guard cookie == magicCookie else { return nil }

    // Verify transaction ID
    guard data.subdata(in: 8..<20) == transactionId else { return nil }

    // Message length
    let msgLength = Int(data.readUInt16(at: 2))
    guard data.count >= 20 + msgLength else { return nil }

    // Parse attributes
    var offset = 20
    var xorResult: (String, UInt16)?
    var plainResult: (String, UInt16)?

    while offset + 4 <= 20 + msgLength {
      let attrType = data.readUInt16(at: offset)
      let attrLength = Int(data.readUInt16(at: offset + 2))

      guard offset + 4 + attrLength <= data.count else { break }

      let attrData = data.subdata(in: (offset + 4)..<(offset + 4 + attrLength))

      if attrType == attrXorMappedAddress {
        xorResult = parseXorMappedAddress(attrData, transactionId: transactionId)
      } else if attrType == attrMappedAddress {
        plainResult = parseMappedAddress(attrData)
      }

      // Attributes are padded to 4-byte boundaries
      offset += 4 + ((attrLength + 3) & ~3)
    }

    // Prefer XOR-MAPPED-ADDRESS (less likely to be mangled by middleboxes)
    return xorResult ?? plainResult
  }

  /// Parse XOR-MAPPED-ADDRESS attribute (RFC 5389 §15.2)
  private static func parseXorMappedAddress(
    _ data: Data,
    transactionId: Data
  ) -> (String, UInt16)? {
    guard data.count >= 8 else { return nil }

    let family = data[1]
    guard family == 0x01 else { return nil } // IPv4 only for now

    // Port is XORed with magic cookie high 16 bits
    let xorPort = data.readUInt16(at: 2)
    let port = xorPort ^ UInt16(magicCookie >> 16)

    // Address is XORed with magic cookie
    let xorAddr = data.readUInt32(at: 4)
    let addr = xorAddr ^ magicCookie

    let a = (addr >> 24) & 0xFF
    let b = (addr >> 16) & 0xFF
    let c = (addr >> 8) & 0xFF
    let d = addr & 0xFF
    let address = "\(a).\(b).\(c).\(d)"

    return (address, port)
  }

  /// Parse MAPPED-ADDRESS attribute (RFC 5389 §15.1)
  private static func parseMappedAddress(_ data: Data) -> (String, UInt16)? {
    guard data.count >= 8 else { return nil }

    let family = data[1]
    guard family == 0x01 else { return nil } // IPv4 only

    let port = data.readUInt16(at: 2)

    let a = data[4]
    let b = data[5]
    let c = data[6]
    let d = data[7]
    let address = "\(a).\(b).\(c).\(d)"

    return (address, port)
  }
}

// MARK: - NAT Type Detection

extension STUNClient {
  /// Detected NAT behavior for hole-punching compatibility.
  public enum NATType: String, Sendable {
    /// Same external port for all destinations — hole-punching works
    case endpointIndependent = "Endpoint-Independent Mapping (hole-punch friendly)"
    /// Different external port per destination — hole-punching will fail
    case symmetric = "Symmetric NAT (hole-punch hostile)"
    /// Could only reach one STUN server — can't determine
    case unknown = "Unknown (insufficient STUN responses)"
    /// No STUN responses at all
    case blocked = "Blocked (no STUN servers reachable)"
  }

  /// Result of NAT type detection
  public struct NATTypeResult: Sendable {
    public let natType: NATType
    public let publicAddress: String?
    public let mappings: [(server: String, address: String, port: UInt16)]
  }

  /// Detect NAT type by querying multiple STUN servers from the same local port.
  /// If the external port is consistent across servers → endpoint-independent (good).
  /// If the external port changes per server → symmetric NAT (bad for hole-punching).
  public static func detectNATType(localPort: UInt16 = 8766) async -> NATTypeResult {
    var results: [(server: String, address: String, port: UInt16)] = []

    // Query at least 2 different STUN servers from the same port
    for server in stunServers.prefix(3) {
      if let result = await queryServer(
        host: server.host,
        port: server.port,
        localPort: localPort,
        timeout: 3
      ) {
        results.append((server: result.serverUsed, address: result.address, port: result.port))
      }
    }

    guard !results.isEmpty else {
      return NATTypeResult(natType: .blocked, publicAddress: nil, mappings: [])
    }

    guard results.count >= 2 else {
      return NATTypeResult(
        natType: .unknown,
        publicAddress: results.first?.address,
        mappings: results
      )
    }

    // Check if external port is consistent across different servers
    let ports = Set(results.map(\.port))
    let natType: NATType = ports.count == 1 ? .endpointIndependent : .symmetric

    logger.info("NAT type detected: \(natType.rawValue) — ports seen: \(ports.sorted())")

    return NATTypeResult(
      natType: natType,
      publicAddress: results.first?.address,
      mappings: results
    )
  }
}

// MARK: - Data Helpers

private extension Data {
  func readUInt16(at offset: Int) -> UInt16 {
    guard offset + 2 <= count else { return 0 }
    return self.withUnsafeBytes { buffer in
      let ptr = buffer.baseAddress!.advanced(by: offset)
        .assumingMemoryBound(to: UInt16.self)
      return ptr.pointee.bigEndian
    }
  }

  func readUInt32(at offset: Int) -> UInt32 {
    guard offset + 4 <= count else { return 0 }
    return self.withUnsafeBytes { buffer in
      let ptr = buffer.baseAddress!.advanced(by: offset)
        .assumingMemoryBound(to: UInt32.self)
      return ptr.pointee.bigEndian
    }
  }
}
