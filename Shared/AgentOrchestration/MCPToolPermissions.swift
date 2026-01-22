//
//  MCPToolPermissions.swift
//  Peel
//
//  Created on 1/22/26.
//

import Foundation

@MainActor
public protocol MCPToolPermissionsProviding: AnyObject {
  func isToolEnabled(_ name: String) -> Bool
  func setToolEnabled(_ name: String, enabled: Bool)
  func resetPermissions()
}

@MainActor
@Observable
public final class MCPToolPermissionsStore: MCPToolPermissionsProviding {
  private let storageKey: String
  private var toolPermissions: [String: Bool] = [:]
  public var onChange: (() -> Void)?

  public init(storageKey: String = "mcp.server.toolPermissions") {
    self.storageKey = storageKey
    load()
  }

  public func isToolEnabled(_ name: String) -> Bool {
    toolPermissions[name] ?? true
  }

  public func setToolEnabled(_ name: String, enabled: Bool) {
    toolPermissions[name] = enabled
    persist()
    onChange?()
  }

  public func resetPermissions() {
    toolPermissions = [:]
    persist()
    onChange?()
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
      toolPermissions = [:]
      return
    }
    toolPermissions = decoded
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(toolPermissions) else { return }
    UserDefaults.standard.set(data, forKey: storageKey)
  }
}
