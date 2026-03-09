import Foundation

enum SwarmPeerPreferences {
  private enum Keys {
    static let preferredLANPeerId = "swarm.preferredLANPeerId"
    static let preferredWANWorkerId = "swarm.preferredWANWorkerId"
  }

  static var preferredLANPeerId: String? {
    get { normalized(UserDefaults.standard.string(forKey: Keys.preferredLANPeerId)) }
    set { set(newValue, forKey: Keys.preferredLANPeerId) }
  }

  static var preferredWANWorkerId: String? {
    get { normalized(UserDefaults.standard.string(forKey: Keys.preferredWANWorkerId)) }
    set { set(newValue, forKey: Keys.preferredWANWorkerId) }
  }

  static func ordered(peers: [ConnectedPeer]) -> [ConnectedPeer] {
    peers.sorted { lhs, rhs in
      if isPreferred(lhs) != isPreferred(rhs) {
        return isPreferred(lhs)
      }
      if lhs.capabilities.memoryGB != rhs.capabilities.memoryGB {
        return lhs.capabilities.memoryGB > rhs.capabilities.memoryGB
      }
      if lhs.capabilities.gpuCores != rhs.capabilities.gpuCores {
        return lhs.capabilities.gpuCores > rhs.capabilities.gpuCores
      }
      if lhs.capabilities.neuralEngineCores != rhs.capabilities.neuralEngineCores {
        return lhs.capabilities.neuralEngineCores > rhs.capabilities.neuralEngineCores
      }
      if lhs.capabilities.indexedRepos.count != rhs.capabilities.indexedRepos.count {
        return lhs.capabilities.indexedRepos.count > rhs.capabilities.indexedRepos.count
      }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  static func ordered(workers: [FirestoreWorker]) -> [FirestoreWorker] {
    workers.sorted { lhs, rhs in
      if isPreferred(lhs) != isPreferred(rhs) {
        return isPreferred(lhs)
      }
      if lhs.isStale != rhs.isStale {
        return !lhs.isStale
      }
      if lhs.lastHeartbeat != rhs.lastHeartbeat {
        return lhs.lastHeartbeat > rhs.lastHeartbeat
      }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  static func defaultPeer(from peers: [ConnectedPeer]) -> ConnectedPeer? {
    ordered(peers: peers).first
  }

  static func defaultWorker(from workers: [FirestoreWorker]) -> FirestoreWorker? {
    ordered(workers: workers).first
  }

  static func isPreferred(_ peer: ConnectedPeer) -> Bool {
    peer.id == preferredLANPeerId
  }

  static func isPreferred(_ worker: FirestoreWorker) -> Bool {
    worker.id == preferredWANWorkerId
  }

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  private static func set(_ value: String?, forKey key: String) {
    if let value = normalized(value) {
      UserDefaults.standard.set(value, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}