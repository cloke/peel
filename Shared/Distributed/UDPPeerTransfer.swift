// UDPPeerTransfer.swift — UDP hole punch + reliable data transfer
//
// After STUN signaling exchange: both sides know each other's external
// UDP endpoint (discovered via STUN binding on port 8766). This class:
//
//   1.  UDP hole punch — both sides send PUNCH datagrams simultaneously.
//       Since STUN already created the NAT mapping for port 8766 (UDP),
//       the peer's packets pass through once both sides' NATs see
//       bidirectional traffic.
//
//   2.  Reliable data transfer — initiator sends REQUEST, responder
//       returns DATA chunks with cumulative ACK and retransmission.
//
// Binary protocol (each UDP datagram):
//   [type: UInt8][payload]
//
//   PUNCH   (0x01)  — 1 byte, no payload. For hole punching.
//   REQUEST (0x02)  — JSON payload: {"repo":"..."}
//   DATA    (0x03)  — [chunkIndex: UInt32 BE][totalChunks: UInt32 BE][bytes]
//   ACK     (0x04)  — [receivedUpTo: UInt32 BE] cumulative
//   FIN     (0x05)  — Transfer complete, no payload.

import Foundation
import Network
import os

/// Provides repo bundle data for UDP transfer responder.
@MainActor
protocol UDPTransferDataProvider: AnyObject {
  func exportRepoBundle(repoIdentifier: String) async throws -> Data
}

@MainActor
final class UDPPeerTransfer {
  private static let logger = Logger(subsystem: "com.peel", category: "UDPPeerTransfer")

  // Protocol constants
  static let chunkPayloadSize = 1200 // bytes per DATA datagram payload
  static let punchCount = 30
  static let punchInterval: Duration = .milliseconds(150)
  static let windowSize = 48 // chunks in flight before waiting for ACK
  static let ackInterval: Duration = .milliseconds(50)
  static let retransmitTimeout: Duration = .seconds(2)
  static let transferTimeout: Duration = .seconds(180)

  enum MsgType: UInt8 {
    case punch = 0x01
    case request = 0x02
    case data = 0x03
    case ack = 0x04
    case fin = 0x05
  }

  enum TransferError: LocalizedError {
    case holePunchFailed
    case timeout
    case noData
    case peerError(String)

    var errorDescription: String? {
      switch self {
      case .holePunchFailed: "UDP hole punch failed — no bidirectional connectivity"
      case .timeout: "UDP transfer timed out"
      case .noData: "Responder returned no data"
      case .peerError(let msg): "Peer error: \(msg)"
      }
    }
  }

  // MARK: - Initiator (request data from peer)

  /// Request repo index data from a peer via UDP hole punch.
  /// Returns the raw repo bundle data (JSON-encoded RAGRepoExportBundle).
  static func requestData(
    peerEndpoint: STUNResult,
    localPort: UInt16,
    repoIdentifier: String,
    timeout: Duration = transferTimeout
  ) async throws -> Data {
    let p2pLog = P2PConnectionLog.shared
    let conn = createUDPConnection(to: peerEndpoint, localPort: localPort)
    defer { conn.cancel() }

    try await startConnection(conn)
    p2pLog.log("udp-transfer", "UDP connection started (initiator)")

    // Phase 1: Hole punch
    let punched = try await holePunch(connection: conn, p2pLog: p2pLog, role: "initiator")
    guard punched else { throw TransferError.holePunchFailed }

    // Phase 2: Send request
    let requestPayload = try JSONEncoder().encode(["repo": repoIdentifier])
    var msg = Data([MsgType.request.rawValue])
    msg.append(requestPayload)
    try await sendDatagram(conn, data: msg)
    p2pLog.log("udp-transfer", "Sent REQUEST", details: ["repo": repoIdentifier])

    // Phase 3: Receive chunked data
    let data = try await receiveChunkedData(connection: conn, timeout: timeout, p2pLog: p2pLog)
    p2pLog.log("udp-transfer", "Transfer complete", details: [
      "bytes": String(data.count),
      "repo": repoIdentifier,
    ])
    return data
  }

  // MARK: - Responder (serve data to peer)

  /// Respond to a UDP transfer request. Called by STUNSignalingResponder
  /// after writing the STUN answer.
  static func serveData(
    peerEndpoint: STUNResult,
    localPort: UInt16,
    dataProvider: UDPTransferDataProvider,
    timeout: Duration = transferTimeout
  ) async {
    let p2pLog = P2PConnectionLog.shared
    let conn = createUDPConnection(to: peerEndpoint, localPort: localPort)
    defer { conn.cancel() }

    do {
      try await startConnection(conn)
      p2pLog.log("udp-transfer", "UDP connection started (responder)")

      // Phase 1: Hole punch
      let punched = try await holePunch(connection: conn, p2pLog: p2pLog, role: "responder")
      guard punched else {
        p2pLog.log("udp-transfer", "Responder hole punch failed")
        return
      }

      // Phase 2: Wait for REQUEST
      let request = try await waitForRequest(connection: conn, timeout: .seconds(30))
      p2pLog.log("udp-transfer", "Received REQUEST", details: ["repo": request.repo])

      // Phase 3: Export bundle with keepalive to prevent NAT timeout.
      // Bundle export can take 30-60s; most NATs expire UDP mappings
      // after 30s of idle. Send PUNCH keepalives every 5s during export.
      let keepaliveTask = Task {
        let punchData = Data([MsgType.punch.rawValue])
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(5))
          guard !Task.isCancelled else { break }
          conn.send(content: punchData, completion: .contentProcessed { _ in })
          p2pLog.log("udp-transfer", "Keepalive PUNCH sent during export")
        }
      }
      let data = try await dataProvider.exportRepoBundle(repoIdentifier: request.repo)
      keepaliveTask.cancel()
      p2pLog.log("udp-transfer", "Exporting bundle", details: [
        "bytes": String(data.count),
        "repo": request.repo,
      ])

      try await sendChunkedData(connection: conn, data: data, timeout: timeout, p2pLog: p2pLog)
      p2pLog.log("udp-transfer", "Responder send complete", details: ["bytes": String(data.count)])

    } catch {
      p2pLog.log("udp-transfer", "Responder error", details: ["error": "\(error)"])
      logger.error("[udp-transfer] Responder error: \(error)")
    }
  }

  // MARK: - Connection Setup

  private static func createUDPConnection(to endpoint: STUNResult, localPort: UInt16) -> NWConnection {
    let host = NWEndpoint.Host(endpoint.address)
    let port = NWEndpoint.Port(rawValue: endpoint.port)!
    let nwEndpoint = NWEndpoint.hostPort(host: host, port: port)

    let params = NWParameters.udp
    params.allowLocalEndpointReuse = true
    if let localNWPort = NWEndpoint.Port(rawValue: localPort) {
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: localNWPort)
    }

    return NWConnection(to: nwEndpoint, using: params)
  }

  private static func startConnection(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let resumed = ContinuationBox()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if resumed.tryResume() {
            continuation.resume()
          }
        case .failed(let error):
          if resumed.tryResume() {
            continuation.resume(throwing: error)
          }
        case .cancelled:
          if resumed.tryResume() {
            continuation.resume(throwing: CancellationError())
          }
        default:
          break
        }
      }
      connection.start(queue: .main)
    }
  }

  // MARK: - Hole Punch

  /// Send PUNCH datagrams while also listening for incoming PUNCHes.
  /// Returns true if bidirectional connectivity is confirmed.
  private static func holePunch(
    connection: NWConnection,
    p2pLog: P2PConnectionLog,
    role: String
  ) async throws -> Bool {
    let punchData = Data([MsgType.punch.rawValue])
    var receivedPunch = false

    // Start a receiver task (no @MainActor — runs on global executor
    // to avoid contention with receiveMessage callbacks on main queue)
    let receiveTask = Task { () -> Bool in
      for _ in 0..<(punchCount * 3) { // Listen longer than we send
        guard !Task.isCancelled else { return false }
        do {
          let data = try await receiveDatagram(connection, timeout: .seconds(10))
          if !data.isEmpty && data[0] == MsgType.punch.rawValue {
            return true
          }
          // Could be a REQUEST or other message — got connectivity anyway
          if !data.isEmpty { return true }
        } catch {
          continue
        }
      }
      return false
    }

    // Send PUNCH packets
    for i in 0..<punchCount {
      guard !Task.isCancelled else { break }
      connection.send(content: punchData, completion: .contentProcessed { _ in })
      if i % 5 == 0 {
        p2pLog.log("udp-transfer", "Sending PUNCH \(i+1)/\(punchCount) [\(role)]")
      }
      try? await Task.sleep(for: punchInterval)
    }

    receivedPunch = await receiveTask.value
    p2pLog.log("udp-transfer", "Hole punch result: \(receivedPunch ? "SUCCESS" : "FAILED") [\(role)]")
    return receivedPunch
  }

  // MARK: - Data Receiving (Initiator)

  private struct TransferRequest: Codable {
    let repo: String
  }

  /// Receive chunked DATA datagrams, send ACKs, reassemble into contiguous Data.
  private static func receiveChunkedData(
    connection: NWConnection,
    timeout: Duration,
    p2pLog: P2PConnectionLog
  ) async throws -> Data {
    var receivedChunks: [UInt32: Data] = [:]
    var totalChunks: UInt32 = 0
    var lastAckSent: UInt32 = 0
    var receiveTimeouts = 0
    let startTime = ContinuousClock.now

    while ContinuousClock.now - startTime < timeout {
      let datagram: Data
      do {
        datagram = try await receiveDatagram(connection, timeout: .seconds(5))
        receiveTimeouts = 0
      } catch {
        receiveTimeouts += 1
        // Send ACK to trigger retransmits
        if totalChunks > 0 {
          let cumAck = cumulativeAck(receivedChunks, total: totalChunks)
          sendACK(connection: connection, receivedUpTo: cumAck)
          if receiveTimeouts % 3 == 1 {
            p2pLog.log("udp-transfer", "Receive timeout, sent ACK", details: [
              "cumAck": String(cumAck),
              "received": "\(receivedChunks.count)/\(totalChunks)",
              "timeouts": String(receiveTimeouts),
            ])
          }
        } else if receiveTimeouts % 3 == 1 {
          p2pLog.log("udp-transfer", "Waiting for first DATA chunk", details: [
            "timeouts": String(receiveTimeouts),
          ])
        }
        continue
      }

      guard !datagram.isEmpty else { continue }
      let msgType = datagram[0]

      if msgType == MsgType.data.rawValue {
        guard datagram.count >= 9 else { continue } // type + chunkIndex(4) + totalChunks(4)
        let chunkIndex = datagram.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let total = datagram.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let chunkData = datagram.subdata(in: 9..<datagram.count)

        totalChunks = total
        receivedChunks[chunkIndex] = chunkData

        // Send ACK periodically
        let cumAck = cumulativeAck(receivedChunks, total: totalChunks)
        if cumAck > lastAckSent + UInt32(windowSize / 2) || cumAck == totalChunks {
          sendACK(connection: connection, receivedUpTo: cumAck)
          p2pLog.log("udp-transfer", "Sent ACK", details: [
            "ackValue": String(cumAck),
            "received": "\(receivedChunks.count)/\(totalChunks)",
            "progress": "\(Int(Double(cumAck) / Double(totalChunks) * 100))%",
          ])
          lastAckSent = cumAck

          if chunkIndex % 100 == 0 || cumAck == totalChunks {
            let pctComplete = totalChunks > 0 ? Int(Double(receivedChunks.count) / Double(totalChunks) * 100) : 0
            p2pLog.log("udp-transfer", "Receiving: \(receivedChunks.count)/\(totalChunks) chunks (\(pctComplete)%)")
          }
        }

        // Check if complete
        if receivedChunks.count == Int(totalChunks) {
          // Send final ACK a few times for reliability
          for _ in 0..<3 {
            sendACK(connection: connection, receivedUpTo: totalChunks)
            try? await Task.sleep(for: .milliseconds(50))
          }

          // Also send FIN
          connection.send(content: Data([MsgType.fin.rawValue]), completion: .contentProcessed { _ in })

          return assembleChunks(receivedChunks, total: totalChunks)
        }
      } else if msgType == MsgType.fin.rawValue {
        // Responder says it's done — check if we have everything
        if receivedChunks.count == Int(totalChunks) && totalChunks > 0 {
          return assembleChunks(receivedChunks, total: totalChunks)
        }
      } else if msgType == MsgType.punch.rawValue {
        // Late punch — ignore
        continue
      }
    }

    if receivedChunks.count == Int(totalChunks) && totalChunks > 0 {
      return assembleChunks(receivedChunks, total: totalChunks)
    }

    throw TransferError.timeout
  }

  // MARK: - Data Sending (Responder)

  private static func waitForRequest(
    connection: NWConnection,
    timeout: Duration
  ) async throws -> TransferRequest {
    let startTime = ContinuousClock.now
    while ContinuousClock.now - startTime < timeout {
      let datagram = try await receiveDatagram(connection, timeout: .seconds(5))
      guard !datagram.isEmpty else { continue }

      if datagram[0] == MsgType.request.rawValue {
        let json = datagram.subdata(in: 1..<datagram.count)
        return try JSONDecoder().decode(TransferRequest.self, from: json)
      }
      // Ignore punch packets that arrive late
    }
    throw TransferError.timeout
  }

  /// Send data in chunks with ACK-based flow control and retransmission.
  private static func sendChunkedData(
    connection: NWConnection,
    data: Data,
    timeout: Duration,
    p2pLog: P2PConnectionLog
  ) async throws {
    let totalChunks = UInt32((data.count + chunkPayloadSize - 1) / chunkPayloadSize)
    var ackedUpTo: UInt32 = 0
    let startTime = ContinuousClock.now

    p2pLog.log("udp-transfer", "Sending \(totalChunks) chunks (\(data.count) bytes)")
    var retransmitCount = 0

    while ackedUpTo < totalChunks {
      guard ContinuousClock.now - startTime < timeout else {
        p2pLog.log("udp-transfer", "Send TIMEOUT", details: [
          "ackedUpTo": String(ackedUpTo),
          "totalChunks": String(totalChunks),
          "retransmits": String(retransmitCount),
        ])
        throw TransferError.timeout
      }

      // Send a window of chunks starting from ackedUpTo
      let windowEnd = min(ackedUpTo + UInt32(windowSize), totalChunks)
      for chunkIndex in ackedUpTo..<windowEnd {
        let offset = Int(chunkIndex) * chunkPayloadSize
        let end = min(offset + chunkPayloadSize, data.count)
        let chunkData = data[offset..<end]

        var datagram = Data([MsgType.data.rawValue])
        var idx = chunkIndex.bigEndian
        var total = totalChunks.bigEndian
        datagram.append(Data(bytes: &idx, count: 4))
        datagram.append(Data(bytes: &total, count: 4))
        datagram.append(chunkData)

        connection.send(content: datagram, completion: .contentProcessed { _ in })
        // Pace sends: 0.5ms between chunks prevents NAT/receiver buffer overflows
        if chunkIndex % 8 == 7 {
          try? await Task.sleep(for: .microseconds(500))
        }
      }

      if ackedUpTo % 200 == 0 || retransmitCount > 0 {
        p2pLog.log("udp-transfer", "Sent chunks \(ackedUpTo)-\(windowEnd-1)/\(totalChunks)", details: [
          "retransmits": String(retransmitCount),
        ])
      }

      // Wait for ACK
      let ack = try await waitForACK(connection: connection, timeout: retransmitTimeout, p2pLog: p2pLog)
      if let ack {
        if ack > ackedUpTo {
          p2pLog.log("udp-transfer", "ACK received", details: [
            "ackValue": String(ack),
            "previousAck": String(ackedUpTo),
            "progress": "\(Int(Double(ack) / Double(totalChunks) * 100))%",
          ])
          ackedUpTo = ack
          retransmitCount = 0
        }
      } else {
        retransmitCount += 1
        if retransmitCount % 5 == 1 {
          p2pLog.log("udp-transfer", "ACK timeout, retransmitting", details: [
            "window": "\(ackedUpTo)-\(windowEnd-1)",
            "retransmitCount": String(retransmitCount),
          ])
        }
      }
    }

    // Send FIN
    for _ in 0..<3 {
      connection.send(content: Data([MsgType.fin.rawValue]), completion: .contentProcessed { _ in })
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private static func waitForACK(
    connection: NWConnection,
    timeout: Duration,
    p2pLog: P2PConnectionLog
  ) async throws -> UInt32? {
    let startTime = ContinuousClock.now
    while ContinuousClock.now - startTime < timeout {
      do {
        let datagram = try await receiveDatagram(connection, timeout: .seconds(1))
        guard datagram.count >= 5 && datagram[0] == MsgType.ack.rawValue else {
          if !datagram.isEmpty {
            p2pLog.log("udp-transfer", "Unexpected msg while waiting for ACK", details: [
              "type": String(format: "0x%02x", datagram[0]),
              "size": String(datagram.count),
            ])
          }
          continue
        }
        let ackValue = datagram.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return ackValue
      } catch {
        return nil // Timeout — caller will retransmit
      }
    }
    return nil
  }

  // MARK: - Helpers

  private static func sendACK(connection: NWConnection, receivedUpTo: UInt32) {
    var msg = Data([MsgType.ack.rawValue])
    var ack = receivedUpTo.bigEndian
    msg.append(Data(bytes: &ack, count: 4))
    connection.send(content: msg, completion: .contentProcessed { _ in })
  }

  /// Calculate how many consecutive chunks from 0 have been received.
  private static func cumulativeAck(_ received: [UInt32: Data], total: UInt32) -> UInt32 {
    var ack: UInt32 = 0
    while ack < total && received[ack] != nil {
      ack += 1
    }
    return ack
  }

  private static func assembleChunks(_ chunks: [UInt32: Data], total: UInt32) -> Data {
    var result = Data()
    for i in 0..<total {
      if let chunk = chunks[i] {
        result.append(chunk)
      }
    }
    return result
  }

  private static func sendDatagram(_ connection: NWConnection, data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      })
    }
  }

  private static func receiveDatagram(_ connection: NWConnection, timeout: Duration) async throws -> Data {
    // IMPORTANT: Do NOT use withThrowingTaskGroup here.
    // Task groups wait for ALL child tasks before returning. If the timeout
    // fires, the group cancels the receive task, but
    // withCheckedThrowingContinuation doesn't auto-resume on cancellation
    // (receiveMessage hasn't called back yet) → the group hangs forever.
    let state = DatagramReceiveState()
    return try await withCheckedThrowingContinuation { continuation in
      state.setContinuation(continuation)

      connection.receiveMessage { content, _, _, error in
        if let error {
          state.tryResume(with: .failure(error))
        } else {
          state.tryResume(with: .success(content ?? Data()))
        }
      }

      Task {
        try? await Task.sleep(for: timeout)
        state.tryResume(with: .failure(TransferError.timeout))
      }
    }
  }
}

/// Thread-safe helper ensuring a CheckedContinuation is resumed exactly once.
/// Used by receiveDatagram to race a receiveMessage callback against a timeout
/// without relying on task groups (which would deadlock — see comment above).
private final class DatagramReceiveState: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false
  private var continuation: CheckedContinuation<Data, Error>?

  func setContinuation(_ cont: CheckedContinuation<Data, Error>) {
    lock.lock()
    continuation = cont
    lock.unlock()
  }

  func tryResume(with result: Result<Data, Error>) {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed, let cont = continuation else { return }
    resumed = true
    cont.resume(with: result)
  }
}
