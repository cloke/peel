//
//  MCPServerConfig.swift
//  Peel
//
//  Configuration abstraction for MCP server settings.
//

import Foundation

@MainActor
public protocol MCPServerConfigProviding: AnyObject {
  func bool(forKey key: String, default defaultValue: Bool) -> Bool
  func integer(forKey key: String, default defaultValue: Int) -> Int
  func string(forKey key: String, default defaultValue: String) -> String
  func stringArray(forKey key: String) -> [String]
  func data(forKey key: String) -> Data?
  func objectExists(forKey key: String) -> Bool
  func set(_ value: Bool, forKey key: String)
  func set(_ value: Int, forKey key: String)
  func set(_ value: String, forKey key: String)
  func set(_ value: Data?, forKey key: String)
}

@MainActor
public final class MCPUserDefaultsConfig: MCPServerConfigProviding {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func bool(forKey key: String, default defaultValue: Bool) -> Bool {
    if defaults.object(forKey: key) == nil {
      return defaultValue
    }
    return defaults.bool(forKey: key)
  }

  public func integer(forKey key: String, default defaultValue: Int) -> Int {
    if defaults.object(forKey: key) == nil {
      return defaultValue
    }
    return defaults.integer(forKey: key)
  }

  public func string(forKey key: String, default defaultValue: String) -> String {
    defaults.string(forKey: key) ?? defaultValue
  }

  public func stringArray(forKey key: String) -> [String] {
    defaults.stringArray(forKey: key) ?? []
  }

  public func data(forKey key: String) -> Data? {
    defaults.data(forKey: key)
  }

  public func objectExists(forKey key: String) -> Bool {
    defaults.object(forKey: key) != nil
  }

  public func set(_ value: Bool, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: Int, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: String, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: Data?, forKey key: String) {
    defaults.set(value, forKey: key)
  }
}