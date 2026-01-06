//
//  KeychainService.swift
//  KitchenSync
//
//  Created on 1/6/26.
//  Modern Swift 6 keychain service for secure token storage
//

import Foundation
import Security

/// Thread-safe keychain service for storing sensitive credentials
actor KeychainService {
  static let shared = KeychainService()
  
  private init() {}
  
  enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case duplicateItem
    case invalidData
    case unexpectedStatus(OSStatus)
    
    var errorDescription: String? {
      switch self {
      case .itemNotFound:
        return "The requested item was not found in the keychain"
      case .duplicateItem:
        return "An item with this key already exists"
      case .invalidData:
        return "The data could not be encoded or decoded"
      case .unexpectedStatus(let status):
        return "Keychain operation failed with status: \(status)"
      }
    }
  }
  
  // MARK: - Save
  
  /// Save a string value to the keychain
  func save(_ value: String, for key: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainError.invalidData
    }
    
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
    ]
    
    // Delete existing item if present
    SecItemDelete(query as CFDictionary)
    
    // Add new item
    let status = SecItemAdd(query as CFDictionary, nil)
    
    guard status == errSecSuccess else {
      throw KeychainError.unexpectedStatus(status)
    }
  }
  
  // MARK: - Retrieve
  
  /// Retrieve a string value from the keychain
  func retrieve(for key: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    
    guard status == errSecSuccess else {
      if status == errSecItemNotFound {
        throw KeychainError.itemNotFound
      }
      throw KeychainError.unexpectedStatus(status)
    }
    
    guard let data = result as? Data,
          let string = String(data: data, encoding: .utf8) else {
      throw KeychainError.invalidData
    }
    
    return string
  }
  
  // MARK: - Delete
  
  /// Delete a value from the keychain
  func delete(for key: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key
    ]
    
    let status = SecItemDelete(query as CFDictionary)
    
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }
  
  // MARK: - Update
  
  /// Update an existing value in the keychain
  func update(_ value: String, for key: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainError.invalidData
    }
    
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key
    ]
    
    let attributes: [String: Any] = [
      kSecValueData as String: data
    ]
    
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    
    guard status == errSecSuccess else {
      if status == errSecItemNotFound {
        // If item doesn't exist, create it
        try save(value, for: key)
        return
      }
      throw KeychainError.unexpectedStatus(status)
    }
  }
}
