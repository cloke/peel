//
//  SignalingChannel.swift
//  WebRTCTransfer
//
//  Protocol for WebRTC signaling. The caller (main app) provides
//  a Firestore-backed implementation that exchanges SDP offers/answers
//  and ICE candidates between peers.
//

import Foundation

/// An ICE candidate to exchange via signaling.
public struct ICECandidateMessage: Sendable, Codable {
  public let sdp: String
  public let sdpMid: String?
  public let sdpMLineIndex: Int32

  public init(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
    self.sdp = sdp
    self.sdpMid = sdpMid
    self.sdpMLineIndex = sdpMLineIndex
  }
}

/// Protocol for exchanging WebRTC signaling data between peers.
/// The main app implements this using Firestore (or any other signaling transport).
public protocol WebRTCSignalingChannel: Sendable {
  /// Send an SDP offer to the remote peer.
  func sendOffer(_ sdp: String) async throws

  /// Send an SDP answer to the remote peer.
  func sendAnswer(_ sdp: String) async throws

  /// Send an ICE candidate to the remote peer.
  func sendCandidate(_ candidate: ICECandidateMessage) async throws

  /// Wait for an SDP offer from the remote peer.
  func waitForOffer(timeout: Duration) async throws -> String

  /// Wait for an SDP answer from the remote peer.
  func waitForAnswer(timeout: Duration) async throws -> String

  /// Stream of ICE candidates from the remote peer.
  func receiveCandidates() -> AsyncStream<ICECandidateMessage>

  /// Clean up signaling documents.
  func cleanup() async
}
