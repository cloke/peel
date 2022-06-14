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
    
    @Published var branches = [Model.Branch]()
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
        let list = try await Commands.Branch.list(from: branchType, on: self)
        print("load type: \(branchType)")
        branches.removeAll(where: { $0.type == branchType })
        branches.append(contentsOf: list)
      } catch {}
    }
    
    @available(macOS 12, *)
    func load() async {
      // TODO: Use a task group
      await loadBranches(branchType: .local)
      await loadBranches(branchType: .remote)
      refreshStatus()
    }
    
    @available(macOS 12, *)
    func refreshStatus() {
      Commands.status(on: self) { self.status = $0 }
    }
    
    @available(macOS 12, *)
    func activate(branch: Model.Branch) {
      branches.forEach { $0.isActive = $0.id == branch.id ? true : false }
    }
    
    @available(macOS 12, *)
    func push(branch: Model.Branch) async throws {
      do {
        _ = try await Commands.push(branch: branch, to: self)
        self.refreshStatus()
      } catch {}
    }
    
    @available(macOS 12, *)
    func delete(branch: Model.Branch) async throws {
      do {
      _ = try await Commands.Branch.delete(name: branch.name, on: self)
        if let index = branches.firstIndex(where: { $0.id == branch.id }) {
          branches.remove(at: index)
        }
      }
    }
    
    enum CodingKeys: String, CodingKey {
      case id, name, path
    }
  }
}
