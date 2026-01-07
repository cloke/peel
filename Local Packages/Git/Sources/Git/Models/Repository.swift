//
//  Repository.swift
//
//
//  Created by Cory Loken on 6/12/22.
//

import Foundation
import Observation

extension Model {
  /// Identifiable container for single git repository
  @Observable
  public class Repository: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var path: String
    
    public var localBranches = [Model.Branch]()
    public var remoteBranches = [Model.Branch]()
    public var status = [FileDescriptor]()
    
    public init(name: String, path: String) {
      self.name = name
      self.path = path
    }
    
    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
      case id, name, path
    }
    
    public required init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(UUID.self, forKey: .id)
      name = try container.decode(String.self, forKey: .name)
      path = try container.decode(String.self, forKey: .path)
    }
    
    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
      try container.encode(path, forKey: .path)
    }
    
    // MARK: - Methods
    
    @available(macOS 12, *)
    @MainActor
    func loadBranches(branchType: Model.BranchType) async {
      // TODO - The array should be built in one pass to reduce weird graphic errors.
      // Maybe wait for swift 6 and use async calls to simplify
      print("🔴 Load branches in \(name)")
      do {
        #if canImport(AppKit)
        let list = try await Commands.Branch.list(from: branchType, on: self)

        print("🔴 load type: \(branchType), count \(list.count)")
        if branchType == .local {
          print("🔴 Setting localBranches")
          localBranches.removeAll()
          localBranches.append(contentsOf: list)
          print("🔴 Done setting localBranches")
        } else {
          print("🔴 Setting remoteBranches")
          remoteBranches.removeAll()
          remoteBranches.append(contentsOf: list)
          print("🔴 Done setting remoteBranches")
        }
        #endif
      } catch {
        print("🔴 Error loading branches: \(error)")
      }
    }
    
    @available(macOS 12, *)
    @MainActor
    func load() async {
      // TODO: Use a task group
      await loadBranches(branchType: .local)
      await loadBranches(branchType: .remote)
      await refreshStatus()
    }
    
    @MainActor
    func refreshStatus() async {
      #if canImport(AppKit)
      if let status = try? await Commands.status(on: self) {
        self.status = status
      }
      #endif
    }
    
    @available(macOS 12, *)
    @MainActor
    func activate(branch: Model.Branch) {
      localBranches.forEach { $0.isActive = $0.id == branch.id ? true : false }
    }
    
    @available(macOS 12, *)
    @MainActor
    func push(branch: Model.Branch) async throws {
      #if canImport(AppKit)
      _ = try await Commands.push(branch: branch, to: self)
      await self.refreshStatus()
      #endif
    }
    
    @MainActor
    func delete(branch: Model.Branch) async throws {
      #if canImport(AppKit)
      _ = try await Commands.Branch.delete(name: branch.name, on: self)
      if let index = localBranches.firstIndex(where: { $0.id == branch.id }) {
        localBranches.remove(at: index)
      }
      #endif
    }
    
    @MainActor
    func delete(branches: [Model.Branch]) async throws {
      for branch in branches {
        try await delete(branch: branch)
      }
    }
  }
}
