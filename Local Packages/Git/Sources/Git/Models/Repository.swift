//
//  Repository.swift
//
//
//  Created by Cory Loken on 6/12/22.
//

import Foundation

extension Model {
  /// Identifiable container for single git repository
  public class Repository: Codable, Identifiable, ObservableObject {
    public var id = UUID()
    public var name: String
    public var path: String
    
    @Published var localBranches = [Model.Branch]()
    @Published var remoteBranches = [Model.Branch]()

    @Published var status = [FileDescriptor]()
    
    init(name: String, path: String) {
      self.name = name
      self.path = path
    }
    
    @available(macOS 12, *)
    func loadBranches(branchType: Model.BranchType) async {
      // TODO - The array should be built in one pass to reduce weird graphic errors.
      // Maybe wait for swift 6 and use async calls to simplify
      print("Load branches in \(name)")
      do {
        #if canImport(AppKit)
        let list = try await Commands.Branch.list(from: branchType, on: self)

        print("load type: \(branchType), count \(list.count)")
        DispatchQueue.main.async { [self] in
          if branchType == .local {
            localBranches.removeAll()
            localBranches.append(contentsOf: list)
          } else {
            remoteBranches.removeAll()
            remoteBranches.append(contentsOf: list)
          }
        }
        #endif
      } catch {}
    }
    
    @available(macOS 12, *)
    func load() async {
      // TODO: Use a task group
      await loadBranches(branchType: .local)
      await loadBranches(branchType: .remote)
      await refreshStatus()
    }
    
    func refreshStatus() async {
      #if canImport(AppKit)
      if let status = try? await Commands.status(on: self) {
        await MainActor.run {
          self.status = status
        }
      }
      #endif
    }
    
    @available(macOS 12, *)
    func activate(branch: Model.Branch) {
      localBranches.forEach { $0.isActive = $0.id == branch.id ? true : false }
    }
    
    @available(macOS 12, *)
    func push(branch: Model.Branch) async throws {
      #if canImport(AppKit)
      _ = try await Commands.push(branch: branch, to: self)
      await self.refreshStatus()
      #endif
    }
    
    func delete(branch: Model.Branch) async throws {
      #if canImport(AppKit)
      _ = try await Commands.Branch.delete(name: branch.name, on: self)
      if let index = localBranches.firstIndex(where: { $0.id == branch.id }) {
        Task { @MainActor in
          localBranches.remove(at: index)
        }
      }
      #endif
    }
    
    func delete(branches: [Model.Branch]) async throws {
      for branch in branches {
        try await delete(branch: branch)
      }
    }
    
    enum CodingKeys: String, CodingKey {
      case id, name, path
    }
  }
}
